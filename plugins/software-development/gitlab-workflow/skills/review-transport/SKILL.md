---
name: review-transport
description: "Post a finished code-review-core review to a GitLab merge request: read .code-review/VALIDATED.json, route each finding to an inline diff discussion or the MR-level summary note depending on in_diff and whether its location parses, build the position object from the MR's diff_refs, and publish the inline notes together after verifying every one of them anchored. Refuses to post when VALIDATED.json is missing or unparseable, because a clean review posted over an unfinished run is worse than no review. Re-runnable without duplicating notes. Use after the review pipeline has run and its verdict needs to reach the MR. NOT a reviewer: it changes no severity and forms no verdict."
license: MIT
when_to_use: "post the review to the merge request, publish code review findings to GitLab, comment the review on the MR, post VALIDATED.json to a GitLab MR, inline comment on a GitLab diff, position object base_sha head_sha start_sha, re-post the review without duplicating notes"
allowed-tools: Bash(glab:*), Bash(jq:*), Bash(git:*), Bash(bash:*), Bash(test:*), Read, Grep, Glob
---

# review-transport

The bridge between a review that has finished and a merge request that has not heard about it.

`code-review-core` writes files and posts nothing. This skill reads those files and posts, and does
nothing else — it re-ranks no finding, resolves no ambiguity in the validator's favour, and never
computes a verdict of its own.

## Order of operations

1. Run the review with `code-review-core` (`pipeline/prepare-context.sh`, then the judgement agents,
   validator last). Nothing here starts until the validator has written `VALIDATED.json`.
2. Check the precondition.
3. Post with `scripts/post-review.sh`, in `--dry-run` first if the MR is one you cannot un-post to.

```bash
glab auth status
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
post an empty review, a "review pending" note, or an approval. This is the single worst failure
available to a transport: an unfinished review posted as a clean one turns "we do not know" into a
green pipeline, and the next human to look will trust it. Refusing is loud; a false approval is
silent.

The same applies to a document with zero findings *and* no `verdict`. That is not an approval, it is
an output with nothing in it, and the script refuses rather than guessing which one was meant.

## Routing a finding

| Finding | Goes to | Why |
| --- | --- | --- |
| `in_diff: true`, `location` parses to `path` + `line` | inline discussion on that line | it is a comment about a line this MR changed |
| `in_diff: false` | a section of the summary note | a GitLab diff note can only anchor to a line inside this MR's diff; outside it, the `position` does not resolve |
| `location` does not parse into `path` + `line` | a section of the summary note | there is nowhere to anchor it |
| already posted in an earlier run | nowhere | see idempotency below |

`location` is the citation string the validator re-read, not a structured field. The parser takes
`path:line` and `path line N` shapes and ignores any trailing column or range. Anything else degrades
to the summary note. **A finding is never dropped for being unplaceable** — a finding that vanishes
because its citation was awkwardly formatted is a finding the author never sees.

`in_diff: false` keeps its severity. It is scoped out of blocking, not relabelled, and it still gets
written into the summary under its own heading so the author can see the pre-existing defect the
review found on the way past.

## The `position` object — the part that is not a find-and-replace of the GitHub adapter

GitHub anchors an inline comment with a path, a line and a side. GitLab will not. A diff note needs a
`position` object, and it needs the merge request's three diff SHAs in it:

```json
{
  "note": "**BLOCKER / authz** Tenant id is not part of the cache key\n\n...",
  "position": {
    "base_sha": "<diff_refs.base_sha>",
    "start_sha": "<diff_refs.start_sha>",
    "head_sha": "<diff_refs.head_sha>",
    "position_type": "text",
    "new_path": "src/auth.py",
    "old_path": "src/auth.py",
    "new_line": 42
  }
}
```

The three SHAs come from the merge request itself and are **not** derivable from the checkout — the
local `HEAD` is not necessarily the SHA GitLab diffed:

```bash
glab api "projects/:id/merge_requests/<iid>" | jq '.diff_refs'
# { "base_sha": "...", "head_sha": "...", "start_sha": "..." }
```

Field-by-field, with the confidence each deserves:

| Field | Certain? | Notes |
| --- | --- | --- |
| `base_sha`, `start_sha`, `head_sha` | yes | copied verbatim from `diff_refs`. All three are required; two out of three is a rejected or unanchored note |
| `position_type` | yes | `"text"` for a line in a source file. `"image"` and `"file"` exist and are not used here |
| `new_path`, `new_line` | yes | the path and line **after** the change — which is what a finding about added code cites |
| `old_path` | **less certain** | GitLab documents it for a text position, and this script sets it equal to `new_path`, which is what the web UI sends for a line added to an existing file. For a file this MR *added* or *renamed*, the correct `old_path` may be different or absent, and `VALIDATED.json` does not say which case a finding is in. If an inline note ever fails to anchor on a newly added file, this field is the first thing to suspect |

There is no `old_line` here on purpose: a position with `new_line` and no `old_line` is an added or
unchanged line, which is the only kind of line an in-diff finding cites.

**A wrong position does not fail loudly on its own.** GitLab answers a POST whose position it cannot
resolve with `201 Created` and `position: null`, and renders the note as an ordinary unanchored
comment. The exit code is 0, the HTTP status is 2xx, and the annotation the author was supposed to
see is not on the line. So every note is verified twice — `.id` must be an integer, and `.position`
must be non-null — and either one missing fails the run.

The `glab` CLI does have a shortcut, `glab mr note create --file <path> --line <n>`, which resolves
the position against the latest diff version for you. `post-review.sh` does not use it: it posts one
note per invocation with no way to assert the note came back anchored, and it has no equivalent of
publishing a verified set together.

## Why draft notes, and what "atomic" means here

GitHub has one endpoint that takes the review body and every inline comment and lands them together.
GitLab has nothing equivalent. The closest available shape is draft notes:

1. `POST projects/:id/merge_requests/:iid/draft_notes` for each inline finding. A draft note is
   invisible to everyone but its author.
2. Verify every one of them (`.id` integral, `.position` non-null).
3. `POST projects/:id/merge_requests/:iid/draft_notes/bulk_publish` once.
4. `POST projects/:id/merge_requests/:iid/notes` for the summary — **after** the inline notes, never
   before. A summary that claims N inline annotations while the annotations failed is a worse
   artifact than no summary.

If any draft fails verification, the script deletes the drafts this run created and exits non-zero.
Nothing was published, so the merge request is exactly as it was. That preserves the invariant the
GitHub adapter gets from a single API call: **a non-zero exit means the MR was not changed** — with
two explicit exceptions, exit 12 and 13, whose messages say precisely what did land.

## Verdict to review event

The validator owns the verdict. The transport translates it:

| `verdict` | Review event | What actually happens on GitLab |
| --- | --- | --- |
| `REQUEST_CHANGES` | `REQUEST_CHANGES` | notes posted; the MR is deliberately left unapproved, and the summary says so |
| `APPROVE` | `APPROVE` | notes posted, then `POST projects/:id/merge_requests/:iid/approve` |
| `INCOMPLETE` | `COMMENT` | notes posted; no approval call of any kind |
| absent | derived from `CODE_REVIEW_BLOCKING_FLOOR` | a derived event never approves |

**GitLab has no API-level "request changes" review event.** Recent GitLab versions expose a reviewer
"requested changes" state in the UI, and this transport deliberately does not depend on it — the
feature is version- and tier-sensitive, and a transport that silently no-ops on an older instance is
the failure mode this plugin is shaped to avoid. What GitLab does have is an approval and the absence
of one, so `REQUEST_CHANGES` is expressed as "the review is posted and this MR is not approved",
stated in the summary body rather than left for the reader to infer.

**`INCOMPLETE` is never posted as an approval.** It means the validator could not finish tracing
something, which is a different state from "this is fine" and must not be collapsed into it. It posts
as a note whose body opens by saying the review is incomplete and, where the document supplies them,
names the `blocking_reason_ids` that were not resolved. The script asserts this rather than trusting
the mapping: an `INCOMPLETE` document that somehow reached an `APPROVE` event exits non-zero.

When `verdict` is absent, the event is derived: any finding with `in_diff: true` whose severity is at
or above `CODE_REVIEW_BLOCKING_FLOOR` (default `MINOR`, ranked `BLOCKER` > `MAJOR` > `MINOR` > `NIT`)
makes it `REQUEST_CHANGES`; otherwise `COMMENT`. A derived verdict never approves — an approval is an
affirmative statement and only the validator gets to make one.

The floor never changes which findings are *posted*. Everything in the document reaches the MR; the
floor only decides which ones are listed as blocking and whether the event requests changes.

Use `--no-approve` on a shared runner or in a pipeline where the token's approval would be
meaningless or unwanted. It suppresses the approve call and nothing else.

## Idempotency

Re-running the transport after fixing three findings must not repost the other seven. Every note the
script writes — inline and summary alike — carries a stable HTML-comment marker naming the finding:

```
<!-- code-review-core:finding:SEM-004 -->
```

The marker is the same one the GitHub adapter uses, because it names the *review core's* finding, not
the forge. It is invisible in rendered Markdown and survives edits to the surrounding prose. Before
posting, the script reads back what is already on the MR and skips anything whose marker it finds:

```bash
MR_IID="$(glab mr view --output json | jq -r '.iid')"
glab api "projects/:id/merge_requests/$MR_IID/notes"       --paginate
glab api "projects/:id/merge_requests/$MR_IID/draft_notes" --paginate
```

Both are read. `notes` covers published notes including the ones inside discussions; `draft_notes`
catches a previous run whose drafts were verified but never published. The marker is grepped out of
the raw response rather than parsed out of it: GitLab bodies carry raw control bytes often enough
that a `jq` over a real merge request's notes dies at parse time, and a parse failure here would look
exactly like "nothing is posted yet" and duplicate the whole review.

If every finding in the document is already present, nothing is posted at all and the script exits 0
saying so — a second run that produces a second identical review is a duplicate, not an update.

Idempotency is keyed on the finding `id`, which is stable across runs for the same defect. A finding
whose content changed but whose id did not will not be reposted; re-run the review from scratch into
a clean `.code-review/` if you need the updated text to reach the MR.

## Running the script

```bash
"$CLAUDE_PLUGIN_ROOT/scripts/post-review.sh" [--mr <iid>] [--project <group>/<project>] \
                                             [--artifacts <dir>] [--dry-run] [--no-approve]
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--mr <iid>` | the MR for the current branch | resolved with `glab mr view --output json` |
| `--project <group>/<project>` | from the checkout's `origin` | required outside a checkout; URL-encoded into the API path, because `glab api` has no `--repo` |
| `--artifacts <dir>` | `.code-review` | where `VALIDATED.json` lives |
| `--dry-run` | off | prints the routing plan and the exact payloads, and makes **no** `glab` call at all. The position SHAs are placeholders, since reading them would be a call |
| `--no-approve` | off | never call the approve endpoint, even on an `APPROVE` verdict |

Exit status is 0 on success and non-zero with a reason on every refusal.

| Exit | Meaning | MR touched? |
| --- | --- | --- |
| 2–9 | bad arguments, missing `jq`, missing/unparseable/empty artifacts, bad floor, unresolvable MR, no `diff_refs`, an `INCOMPLETE` that reached `APPROVE` | no |
| 10 | a draft note failed to verify; the drafts this run created were deleted | no |
| 11 | `bulk_publish` failed; the drafts were deleted | no |
| 12 | the inline notes published but the summary did not | **yes** — re-run, it will skip them and retry the summary |
| 13 | the review posted but the approval call failed | **yes** — the MR carries the review and is not approved |

## Safety

Findings are untrusted text. They are written by agents reading a diff, and a diff can contain
`$(...)`, backticks and semicolons — a review of a shell script routinely does.

The script never builds a command string and never evaluates one. Every finding value is carried from
`VALIDATED.json` into the API payload by `jq`, which quotes and escapes it as JSON, and the payload
reaches `glab` through a file, never through an argument. Nothing derived from a finding is ever
expanded by the shell. When you extend the script, keep that property: the moment a finding's text
becomes part of something a shell parses, a review comment becomes code execution.

The file-not-argv rule earns its place twice over on GitLab, where a tool-permission layer that
inspects command text will deny an entire call for containing a quoted command inside a finding's
evidence — the review then costs its full runtime and produces nothing.

## Surface

Claude Code only. The script is bash and every step needs `glab`; Cowork has no shell to run either
in.
