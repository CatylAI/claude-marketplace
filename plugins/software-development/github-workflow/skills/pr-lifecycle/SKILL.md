---
name: pr-lifecycle
description: "Drive a GitHub pull request end to end with the gh CLI: open one from the current branch (including when it has no upstream), read its review state and CI status without polling in a loop, wait on checks and triage the ones that fail, fetch and reply to review comments thread by thread, flip a draft to ready, and merge with the strategy the repository actually permits. Use when a branch is ready for a PR, when a PR's checks are red, when review feedback needs addressing, or when a PR is ready to land. Every command here is literal and copy-pasteable. NOT a reviewer — it moves a PR through its states, it does not judge the diff."
license: MIT
when_to_use: "open a pull request, gh pr create, push a branch and open a PR, check PR status, why are my checks failing, gh pr checks, wait for CI, address review comments, resolve review threads, mark PR ready for review, squash merge, how should I merge this PR"
allowed-tools: Bash(gh:*), Bash(git:*), Bash(jq:*), Read, Grep, Glob
---

# pr-lifecycle

A pull request is a state machine: unopened, draft, open with red checks, open with feedback,
mergeable, merged. Each state has one correct next command. This skill is those commands, literally.

Nothing here guesses at repository policy. Merge strategy, required checks and branch protection are
properties of the repository, and every one of them is readable — so read it rather than assuming.

## Preconditions

```bash
gh auth status
```

If that is not clean, stop. Every command below fails in a way that looks like a different problem
when authentication is the actual one. Outside a checkout, or when `origin` is ambiguous, add
`--repo <owner>/<repo>` to every `gh` call.

## Opening a pull request

Establish where you are first. A PR opened from the wrong base is a nuisance to fix afterwards.

```bash
git branch --show-current
git status --short
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

If the branch has no upstream, `gh pr create` would otherwise prompt. Push it explicitly:

```bash
git push --set-upstream origin "$(git branch --show-current)"
```

Then open the PR. The title carries the issue key the branch name encodes; the body says what
changed and why, because the diff already says how.

```bash
gh pr create \
  --base main \
  --title "PROJ-123: rotate the token cache on tenant change" \
  --body "$(cat <<'BODY'
## What changed

The token cache key now includes the tenant id, and the cache is cleared on tenant switch.

## Why

Two tenants sharing one process could observe each other's cached tokens. Keying by tenant alone
fixes the collision; clearing on switch fixes the window between switch and first miss.

## Verification

- Added `test_cache_is_scoped_per_tenant`, which fails on the previous implementation.
- Existing suite green.

Refs PROJ-123
BODY
)"
```

To derive the title's issue key from a branch named `PROJ-123-rotate-token-cache`:

```bash
git branch --show-current | sed -n 's/^\([A-Z][A-Z0-9]*-[0-9]*\).*/\1/p'
```

An empty result means the branch does not encode a key — write a plain descriptive title rather than
inventing one.

Open it as a draft when CI has not run yet or the work is deliberately incomplete:

```bash
gh pr create --draft --base main --title "PROJ-123: rotate the token cache" --body "Work in progress."
gh pr ready            # flip it to ready when it is
gh pr ready --undo     # push it back to draft
```

## Reading state

One command per question, each returning JSON you can act on. None of these mutate anything.

```bash
# The whole picture for the current branch's PR
gh pr view --json number,title,state,isDraft,mergeable,mergeStateStatus,reviewDecision,url

# Just the review decision: APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | null
gh pr view --json reviewDecision --jq '.reviewDecision'

# Every check, one line each
gh pr checks

# The failing ones only, as JSON
gh pr checks --json name,state,link --jq '.[] | select(.state != "SUCCESS")'
```

`mergeable` is GitHub's answer to "does this conflict"; `mergeStateStatus` is its answer to "would
the merge button be green" (`CLEAN`, `BLOCKED`, `BEHIND`, `DIRTY`, `UNSTABLE`). They answer different
questions and a PR can be `MERGEABLE` and `BLOCKED` at once — a required check has not passed.

## Waiting on checks

Do not poll in a tight loop. `gh` has a blocking form that consumes no API quota per iteration and
exits non-zero when a check fails:

```bash
gh pr checks --watch --fail-fast
```

Use `--interval 30` to slow it down on a long build. When it exits non-zero, get the failure before
doing anything else:

```bash
gh pr checks --json name,state,link --jq '.[] | select(.state == "FAILURE")'
gh run list --branch "$(git branch --show-current)" --limit 5
gh run view <run-id> --log-failed
```

`--log-failed` prints only the failing steps' output, which is the difference between reading fifty
lines and reading fifty thousand. Triage in this order:

1. **Reproduce locally.** A test that fails in CI and passes locally is usually an environment or
   ordering difference, and chasing it in CI costs a push per attempt.
2. **Read the failing step, not the job summary.** The summary says which job; the step says why.
3. **Re-run only if you have reason to believe it is flaky**, and say so:
   `gh run rerun <run-id> --failed`. A re-run without a hypothesis is how a real failure gets
   merged.

## Addressing review feedback

Inline review comments are not issue comments and do not come back from `gh pr view`. Fetch them
from the API:

```bash
OWNER_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
PR="$(gh pr view --json number --jq '.number')"

gh api "repos/$OWNER_REPO/pulls/$PR/comments" --paginate \
  --jq '.[] | {id, path, line, user: .user.login, body}'
```

Top-level review bodies and the review events (`APPROVED`, `CHANGES_REQUESTED`) come from a different
endpoint:

```bash
gh api "repos/$OWNER_REPO/pulls/$PR/reviews" --paginate \
  --jq '.[] | {id, state, user: .user.login, body}'
```

Work each comment, then reply in its own thread so the conversation stays attached to the line.
Replying to comment `<comment-id>` uses the replies endpoint:

```bash
gh api --method POST \
  "repos/$OWNER_REPO/pulls/$PR/comments/$COMMENT_ID/replies" \
  -f body='Fixed in 4f2a1c9 — the cache key now includes the tenant id.'
```

Push the fixes, then say so once at the PR level rather than per comment:

```bash
git push
gh pr comment --body 'Pushed fixes for all four comments; each thread has the commit that addresses it.'
```

Ask for the re-review explicitly — a push alone does not re-request one:

```bash
gh pr edit --add-reviewer <username>
```

Disagreeing with a comment is a legitimate outcome. Reply with the reason in the thread; do not
silently leave it unaddressed, and do not change code you believe is correct to close a thread.

## Merging

The repository decides which strategies exist. Read it, do not assume:

```bash
gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed
```

Pick the flag matching a permitted strategy — passing one the repository disallows fails with a
message that reads like a permissions problem:

| Repository setting | Flag |
| --- | --- |
| `squashMergeAllowed: true` | `gh pr merge --squash` |
| `mergeCommitAllowed: true` | `gh pr merge --merge` |
| `rebaseMergeAllowed: true` | `gh pr merge --rebase` |

```bash
# Merge now, deleting the branch afterwards
gh pr merge --squash --delete-branch

# Or queue it: merges as soon as required checks pass, without a human waiting
gh pr merge --squash --auto --delete-branch
```

`--auto` is the right default when checks are slow and the PR is approved. It is the wrong default
when you have not read the checks at all — auto-merge will happily land a PR whose only green checks
are the ones that are not required.

If the base has moved and the repository requires branches to be up to date:

```bash
gh pr update-branch
```

Confirm the landing rather than assuming the command that returned 0 did what you meant:

```bash
gh pr view --json state,mergedAt,mergeCommit --jq '{state, mergedAt, sha: .mergeCommit.oid}'
```

## Surface

Claude Code only. Every command above needs a shell and a checkout; neither exists in Cowork.
