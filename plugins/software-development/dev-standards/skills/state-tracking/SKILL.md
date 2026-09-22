---
name: state-tracking
license: MIT
description: A file format and directory convention for state that must survive a context compaction, a new session or a handoff — required timestamp and status fields, checkpoint structure, single-writer rules for concurrent agents, and what "resumable" actually requires. Use when a task spans more than one session, when several agents write coordination files, or when deciding where a progress file should live.
---

# State Tracking

State written during a long task exists for one reader: whoever picks the work up after the
current context is gone. That reader has none of what is in your head right now. Everything
they need has to be on disk.

## Required fields

Every persistent state file carries these, whatever else it holds:

```yaml
created: "2026-01-15T10:30:00Z"   # ISO 8601 UTC, written once
updated: "2026-01-15T11:45:00Z"   # ISO 8601 UTC, rewritten on every write
status: "in_progress"             # open | in_progress | blocked | resolved | closed
```

`updated` is what tells a reader whether the file describes the current world or a run that
died two days ago. A state file without it is indistinguishable from a stale one.

## Checkpoints

Write a checkpoint at natural boundaries: before anything risky or irreversible, after each
phase completes, and on any error.

```markdown
## Checkpoint: {phase name}

**Timestamp:** {ISO 8601}
**Status:** completed | failed | in_progress

**What was done:**
- {action}

**What's next:**
- {step}

**Context for resumption:**
- {the detail that is only in working memory right now}
```

The last section is the one that matters and the one most often left empty. It is for the
things that are not recoverable by re-reading the code: why an obvious approach was
rejected, which of two plausible interpretations of the requirement was chosen, what a
flaky test did on the third run.

## What "resumable" requires

A state file is resumable when a fresh reader can continue without asking a question:

- Current status and phase
- Decisions made, and the reason for each
- Files modified so far
- Remaining work items, concretely enough to start on
- Blockers and open questions, with who or what can unblock them

Test it by asking: if this session ended right now, could someone else finish the work from
this file alone? If not, the missing piece is what belongs in "context for resumption".

## Where state lives

| Kind of state | Location | Notes |
| --- | --- | --- |
| Work on one repo, one session | A dot-directory at the repo root, e.g. `.code-review/`, `.orchestration/` | Add it to `.gitignore` |
| Work spanning several repos or worktrees | Outside any repo, e.g. `~/.<tool>/<slug>/` | Keeps coordination files out of every participant's `git status` |
| Anything a human should read later | Committed docs (`docs/adr/`, a PR description) | State files are scratch, not a record |

Never commit scratch state. A progress file in history dirties every future diff, and its
content is wrong the moment it is merged.

## Concurrency

When more than one process writes state at once, the format has to say who owns what.

- **One writer per file.** The cheap way to make concurrent writes safe is to give each
  writer its own file (`workers/<name>.json`) and have readers aggregate.
- **Declare the writer in the file**, and make it match the path. A file whose declared
  writer disagrees with its location is a bug you can detect.
- **A shared aggregate file needs a single owner.** A load-modify-save with no lock is safe
  for one session and silently lossy for two — the second write overwrites the first
  process's changes with a stale snapshot.
- **A shared directory needs narrow patterns.** If two tools write into the same
  dot-directory, each must name only its own files, never a wildcard.

## What does not need state

A read-only analysis that returns a verdict in one shot keeps nothing. State is for the
iterative loop that owns the fix — the analyst it calls is stateless by design. Writing a
state file for a single-shot operation adds a stale artifact and buys nothing.
