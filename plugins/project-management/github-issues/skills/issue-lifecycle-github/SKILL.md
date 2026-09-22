---
name: issue-lifecycle-github
description: "Carry out the pre-work gate and the issue comment trail against GitHub with the gh CLI — find or create a scoped assigned issue before writing code, read its full state including comments, derive the branch name and pull request title from it, post the start, handoff and finish comments, and close or reopen it with an honest reason. Use at the start of any implementation task in a GitHub repository, when opening a pull request, when pausing mid-stream, and when a change merges."
license: MIT
---

# Issue Lifecycle on GitHub

`pre-work-gate` and `issue-lifecycle` in `issue-tracker-core` say what must be
true and what must be recorded. This skill is how that happens with `gh`.

Every command below is literal. Substitute `<owner>/<repo>` and the issue number;
change nothing else. Where a command is run outside the repository checkout, add
`--repo <owner>/<repo>`.

## Step 1 — Find the key

Branch first, per the core's search order:

```
git branch --show-current
```

Match the result against the configured `CLAUDE_TICKET_PATTERN`. In a GitHub
repository that pattern is the one the repo chose for the prefix seam — see the
plugin root `SKILL.md`. With the preferred `GH-[0-9]+` convention:

```
git branch --show-current | grep -oE 'GH-[0-9]+' | head -1 | cut -d- -f2
```

That prints the bare issue number. No match means no key on the branch; fall
through to the user's message, then to earlier session context, then ask.

## Step 2 — Fetch the issue, do not trust the key

A key proves someone typed a string. Read the issue:

```
gh issue view 123 --json number,title,state,stateReason,assignees,labels,milestone,url,body
```

If that exits non-zero, the issue does not exist or you cannot see it. Stop and
ask; do not create one to make the gate pass.

Render the one-line summary the core requires before doing anything else:

```
gh issue view 123 --json number,title,state,assignees,labels \
  --jq '"[#\(.number)] \(.title) — State: \(.state) — Labels: \(.labels|map(.name)|join(",")) — Assignees: \(.assignees|map(.login)|join(","))"'
```

## Step 3 — Read the full state, including comments

The gate's scope check needs the comment thread, not just the body. A scope
negotiation from three weeks ago lives there.

```
gh issue view 123 --comments
```

Machine-readable form, for when you need to reason over it:

```
gh issue view 123 --json number,title,body,state,stateReason,labels,milestone,assignees,url,comments \
  --jq '{number, title, state, stateReason, labels: [.labels[].name], milestone: .milestone.title, comments: [.comments[] | {author: .author.login, createdAt, body}]}'
```

## Step 4 — Satisfy the gate

Four properties, four repairs.

**Exists** — Step 2 succeeded.

**Assigned** — if `assignees` is empty, or the assignee is not whoever is doing
the work:

```
gh issue edit 123 --add-assignee @me
```

`@me` resolves to the authenticated account. Assigning someone else uses their
login: `--add-assignee <login>`. GitHub caps assignees at ten per issue.

**Workable state** — GitHub has only `open` and `closed`. The in-progress claim is
carried by a label or a Projects v2 field; see `triage-and-labels`. With the
label convention:

```
gh issue edit 123 --remove-label "status:ready" --add-label "status:in-progress"
```

Do this before the first edit to a source file, not at the end of the session.

**Parented** — a milestone, a sub-issue link to a parent, or both. See
`milestones-and-sub-issues`.

### When no suitable issue exists

Create one. A created issue must be scoped, assigned and parented in the same
action, because a follow-up step is the step that does not happen:

```
gh issue create \
  --title "Add retry logic to the ingestion worker" \
  --body-file - \
  --assignee @me \
  --label "type:bug,status:in-progress,area:ingestion" \
  --milestone "2026.Q1" <<'BODY'
## Problem

The ingestion worker aborts the batch on the first transient upstream 503.

## Acceptance

- Transient 5xx responses are retried with backoff, bounded at 5 attempts.
- A permanently failing record is quarantined, not retried forever.
- The retry count is visible in the worker's existing structured log line.
BODY
```

`gh issue create` prints the new issue's URL on stdout. Capture the number from
it rather than re-querying:

```
url=$(gh issue create --title "..." --body "..." --assignee @me)
number=${url##*/}
```

Creating a new issue does not exempt you from the scope check — it *is* the scope
check's remedy. If the user asked for one thing and an existing issue covers a
different thing, the correct output is a new issue plus a sentence saying which
issue the work now attaches to.

## Step 5 — Branch, title, scope

The core's rule: the key must be recoverable from the branch name. With the
`GH-` convention:

```
git switch -c feature/GH-123-retry-ingestion-worker
```

Everything downstream is then mechanical:

| Artefact | Value | Derived how |
| --- | --- | --- |
| Commit scope | `GH-123` | The pattern match on the branch. |
| Pull request title | `fix(GH-123): retry transient upstream failures` | Type from the branch prefix, scope from the key. |
| Pull request body link | `Fixes #123` | The key with `GH-` stripped and `#` prepended. |
| Later search | `gh issue view 123`, `git log --grep GH-123` | One token, two systems. |

The prefix-to-type mapping is the core's: `feature` → `feat`, `fix` → `fix`,
`refactor` → `refactor`, `chore` → `chore`, `docs` → `docs`.

Recover the whole set from a branch in one go:

```
branch=$(git branch --show-current)
key=$(grep -oE 'GH-[0-9]+' <<< "$branch" | head -1)
number=${key#GH-}
type=${branch%%/*}
echo "key=$key number=$number branch-prefix=$type"
```

If `key` comes back empty, the branch predates the convention. Per the core: ask
for the number, then fix the pull request title rather than renaming a branch
someone else may have checked out.

## Step 6 — The comment trail

Three comments are mandatory. `gh issue comment` posts them; `--body-file -`
reads stdin so a multi-paragraph comment does not have to survive shell quoting.

**Start** — the approach, anything the description got wrong, and the branch:

```
gh issue comment 123 --body-file - <<'BODY'
Starting on `fix/GH-123-retry-ingestion-worker`.

Plan: wrap the existing upstream client in a bounded retry with exponential
backoff, so no call site changes. The description assumes the worker already
distinguishes transient from permanent failures — it does not, so this adds that
classification first.
BODY
```

**Handoff or pause** — where things stand, what is known-broken, the single next
step:

```
gh issue comment 123 --body-file - <<'BODY'
Pausing here. Retry wrapper is written and unit-tested. The integration test
against the staging queue fails on expired fixtures, which is unrelated to this
change.

Next step: refresh the fixtures under `test/fixtures/queue/`, then open the pull
request.
BODY
```

Pair the pause with the state move the core requires — an item is not left
claiming in-progress while nobody is on it:

```
gh issue edit 123 --remove-label "status:in-progress" --add-label "status:blocked"
```

**Finish** — the merged change and the acceptance confirmation:

```
gh issue comment 123 --body-file - <<'BODY'
Merged in #131. Acceptance criteria 1 and 2 verified in the integration suite;
criterion 3 (retry count in the log line) is covered by the new assertion in
`worker_log_test`.

Quarantine of permanently-failing records was split out as agreed — see #132.
BODY
```

What does not get a comment: "still working on this". The core is explicit that
routine progress noise trains readers to skim the thread.

### Verify the comment landed

The core requires reading back anything automation claimed to do. `gh issue
comment` is quiet on success, so confirm:

```
gh issue view 123 --json comments --jq '.comments[-1] | {author: .author.login, createdAt, body}'
```

## Step 7 — Closing

Prefer the mechanical link. Put the closing keyword in the pull request body and
let the merge close the issue:

```
gh pr create \
  --title "fix(GH-123): retry transient upstream failures" \
  --body-file - <<'BODY'
Fixes #123

Bounded retry with exponential backoff around the upstream client, plus a
transient/permanent classification the worker did not previously have.
BODY
```

Why this is preferred over closing by hand: the merge and the close become one
event, the issue records which pull request closed it, and there is no window in
which the issue claims done while the change is unmerged — the exact false claim
`status-vocabulary` warns about. GitHub's closing keywords are `close`, `closes`,
`closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`, each
followed by `#<number>`. They act only when the pull request merges into the
repository's default branch.

Closing by hand is for issues with no code change behind them. The reason is not
optional — it is the only place GitHub distinguishes finished from abandoned,
which is the distinction the core says must survive any mapping:

```
gh issue close 123 --reason completed --comment "Shipped in #131."
```

```
gh issue close 123 --reason "not planned" --comment "Superseded by the queue rewrite in #140. Not doing this separately."
```

`completed` maps to the core's **done**; `not planned` maps to **declined**.
Neither maps to **parked** — GitHub has no deferred state, so a parked item stays
open with a `status:parked` label and a comment naming the revisit condition.
Closing a parked item as `not planned` is a lie the backlog will believe.

## Step 8 — Reopening

```
gh issue reopen 123 --comment "Reopening: the retry bound is respected per call, not per batch, so a poisoned batch still spins. Original fix in #131 stands; this is the missing outer bound."
```

Reopening retracts the done claim, so the labels must retract with it. A reopened
issue carrying `status:done` asserts two contradictory things at once:

```
gh issue edit 123 --remove-label "status:done" --add-label "status:in-progress"
```

Reopening also does not re-derive a branch. If the original branch is merged and
deleted, cut a new one against the same key — `fix/GH-123-bound-retries-per-batch`
is a legitimate second branch for one issue. Two branches, one key, one history:
that is the convention working, not a violation of it.

## Common failures

| Symptom | Cause | Repair |
| --- | --- | --- |
| `gh issue view` exits with `Could not resolve to an Issue` | Wrong repo context, or the number is a pull request in another repo. | Add `--repo <owner>/<repo>`. |
| Gate finds no key on an obviously named branch | `CLAUDE_TICKET_PATTERN` still at the default `[A-Z][A-Z0-9]+-[0-9]+`, which a GitHub repo never matches unless the `GH-` convention is adopted. | Set the variable per the plugin root `SKILL.md`. |
| Merged pull request did not close the issue | Keyword used the synthetic prefix (`Fixes GH-123`), or the pull request targeted a non-default branch. | Use `#123`; close by hand if the target branch was intentional. |
| Issue closed with no reason recorded | `gh issue close` without `--reason` defaults to completed. | `gh issue reopen`, then close again with the right reason. |

`gh` 2.93.0 accepts three reasons: `completed`, `"not planned"` and `duplicate`.
Note the spelling difference — the CLI takes `"not planned"` with a space, while
the REST API's field value is `not_planned`. A script that shells out to `gh`
and a script that calls the API directly do not share the literal.
