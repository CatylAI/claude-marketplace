---
name: review-transport
description: "Post a finished code-review-core review to a GitHub pull request: read .code-review/VALIDATED.json, route each finding to an inline thread or the review body depending on in_diff and whether its location parses, and submit one review whose event follows the validator's verdict — REQUEST_CHANGES, APPROVE, or COMMENT for INCOMPLETE. Refuses to post when VALIDATED.json is missing or unparseable, because a clean review posted over an unfinished run is worse than no review. Re-runnable without duplicating threads. Use after the review pipeline has run and its verdict needs to reach the PR. NOT a reviewer: it changes no severity and forms no verdict."
license: MIT
when_to_use: "post the review to the PR, publish code review findings to GitHub, comment the review on the pull request, request changes from the review results, upload VALIDATED.json to a PR, re-post the review without duplicating comments"
allowed-tools: Bash(gh:*), Bash(jq:*), Bash(git:*), Bash(bash:*), Bash(test:*), Read, Grep, Glob
---

# review-transport

The bridge between a review that has finished and a pull request that has not heard about it.

`code-review-core` writes files and posts nothing. This skill reads those files and posts, and does
nothing else — it re-ranks no finding, resolves no ambiguity in the validator's favour, and never
computes a verdict of its own.

## Order of operations

1. Run the review with `code-review-core` (`pipeline/prepare-context.sh`, then the judgement agents,
   validator last). Nothing here starts until the validator has written `VALIDATED.json`.
2. Check the precondition.
3. Post with `scripts/post-review.sh`, in `--dry-run` first if the PR is one you cannot un-post to.

```bash
gh auth status
jq --version
test -f .code-review/VALIDATED.json && jq empty .code-review/VALIDATED.json && echo "review finished"

"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh" --dry-run
"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh"
```

## The precondition, and why it is absolute

`.code-review/VALIDATED.json` must exist and parse. The validator writes it last and writes it whole,
so a partial run leaves no file rather than a truncated one — which makes "the file is there and
parses" a trustworthy completion signal.

If it is absent or unparseable, **the review did not finish, and the transport refuses**. It does not
post an empty review, a "review pending" comment, or an approval. This is the single worst failure
available to a transport: an unfinished review posted as a clean one turns "we do not know" into a
green check, and the next human to look will trust it. Refusing is loud; a false approval is silent.

The same applies to a document with zero findings *and* no `verdict`. That is not an approval, it is
an output with nothing in it, and the script refuses rather than guessing which one was meant.

## Routing a finding

| Finding | Goes to | Why |
| --- | --- | --- |
| `in_diff: true`, `location` parses to `path` + `line` | inline review comment on that line | it is a comment about a line this PR changed |
| `in_diff: false` | a section of the review body | GitHub's review API rejects an inline comment on a line outside the diff; the request fails and takes the *whole review* with it |
| `location` does not parse into `path` + `line` | a section of the review body | there is nowhere to anchor it |
| already posted in an earlier run | nowhere | see idempotency below |

`location` is the citation string the validator re-read, not a structured field. The parser takes
`path:line` and `path line N` shapes and ignores any trailing column or range. Anything else degrades
to the body. **A finding is never dropped for being unplaceable** — a finding that vanishes because
its citation was awkwardly formatted is a finding the reviewer never sees.

`in_diff: false` keeps its severity. It is scoped out of blocking, not relabelled, and it still gets
written into the body under its own heading so the author can see the pre-existing defect the review
found on the way past.

## Verdict to review event

The validator owns the verdict. The transport translates it, one to one:

| `verdict` | Review event | `gh` equivalent |
| --- | --- | --- |
| `REQUEST_CHANGES` | `REQUEST_CHANGES` | `gh pr review --request-changes --body '...'` |
| `APPROVE` | `APPROVE` | `gh pr review --approve --body '...'` |
| `INCOMPLETE` | `COMMENT` | `gh pr review --comment --body '...'` |
| absent | derived from `CODE_REVIEW_BLOCKING_FLOOR` | — |

**`INCOMPLETE` is never posted as an approval.** It means the validator could not finish tracing
something, which is a different state from "this is fine" and must not be collapsed into it. It posts
as a comment whose body opens by saying the review is incomplete and, where the document supplies
them, names the `blocking_reason_ids` that were not resolved.

When `verdict` is absent, the event is derived: any finding with `in_diff: true` whose severity is at
or above `CODE_REVIEW_BLOCKING_FLOOR` (default `MINOR`, ranked `BLOCKER` > `MAJOR` > `MINOR` > `NIT`)
makes it `REQUEST_CHANGES`; otherwise `COMMENT`. Note that a derived verdict never approves — an
approval is an affirmative statement and only the validator gets to make one.

The floor never changes which findings are *posted*. Everything in the document reaches the PR; the
floor only decides which ones are listed as blocking and whether the event requests changes.

`scripts/post-review.sh` submits one review containing the body and every inline comment in a single
API call, rather than a `gh pr review` plus a loop of comment posts. One call means the review is
atomic: either the whole thing lands or none of it does, and a rejected inline comment cannot leave
half a review on the PR.

## Idempotency

Re-running the transport after fixing three findings must not repost the other seven. Every comment
the script writes — inline and body alike — carries a stable HTML-comment marker naming the finding:

```
<!-- code-review-core:finding:SEM-004 -->
```

The marker is invisible in rendered Markdown and survives edits to the surrounding prose. Before
posting, the script reads back what is already on the PR and skips anything whose marker it finds:

```bash
OWNER_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
PR="$(gh pr view --json number --jq '.number')"

gh api "repos/$OWNER_REPO/pulls/$PR/comments" --paginate --jq '.[].body'
gh api "repos/$OWNER_REPO/pulls/$PR/reviews"  --paginate --jq '.[].body'
```

Both endpoints are read, because a finding may have landed either inline or in a body. If every
finding in the document is already present, nothing is posted at all and the script exits 0 saying
so — a second run that produces a second identical review is a duplicate, not an update.

Idempotency is keyed on the finding `id`, which is stable across runs for the same defect. A finding
whose content changed but whose id did not will not be reposted; re-run the review from scratch into
a clean `.code-review/` if you need the updated text to reach the PR.

## Running the script

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh" [--pr <number>] [--repo <owner>/<repo>] \
                                             [--artifacts <dir>] [--dry-run]
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--pr <number>` | the PR for the current branch | resolved with `gh pr view --json number` |
| `--repo <owner>/<repo>` | from the checkout's `origin` | required outside a checkout |
| `--artifacts <dir>` | `.code-review` | where `VALIDATED.json` lives |
| `--dry-run` | off | prints the routing plan and the exact JSON payload, and makes **no** `gh` call at all |

Exit status is 0 on success and non-zero with a reason on every refusal: `jq` missing, artifacts
missing, unparseable JSON, an empty document, an invalid blocking floor, or a `gh` failure. A
non-zero exit from this script always means nothing was posted.

## Safety

Findings are untrusted text. They are written by agents reading a diff, and a diff can contain
`$(...)`, backticks and semicolons — a review of a shell script routinely does.

The script never builds a command string and never evaluates one. Every finding value is carried from
`VALIDATED.json` into the API payload by `jq`, which quotes and escapes it as JSON, and the payload
reaches `gh` through a file, never through an argument. Nothing derived from a finding is ever
expanded by the shell. When you extend the script, keep that property: the moment a finding's text
becomes part of something a shell parses, a review comment becomes code execution.

## Surface

Claude Code only. The script is bash and every step needs `gh`; Cowork has no shell to run either in.
