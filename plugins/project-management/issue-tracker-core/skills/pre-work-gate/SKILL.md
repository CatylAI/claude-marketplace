---
name: pre-work-gate
license: MIT
description: The blocking check that runs before any development work — confirm a tracked issue exists, is assigned, sits in a workable state, and actually covers the request, before writing code, editing source, creating a branch or starting a refactor. Use at the start of any implementation task, and whenever a request arrives with no issue key attached.
---

# Pre-Work Gate

The highest-value habit in tracker discipline, and the cheapest to skip. Run it
**before** the first edit, not after the change is written and someone asks what
it was for.

## When the gate applies

Any task that changes the repository: writing code, editing source or config,
creating a branch or worktree, implementing a feature, fixing a defect,
refactoring, or bumping a dependency.

## When it does not

- Read-only exploration: reading files, answering questions about the codebase.
- Reviewing someone else's change.
- Triage, grooming, or estimating in the tracker itself.
- Documentation-only questions where nothing is written.
- Inspecting build output, logs or infrastructure plans without changing them.

If you are unsure which side a task falls on, run the gate. A needless check
costs one lookup; a missing one costs an untracked change.

## Procedure

1. **Find the key.** Look in this order, stopping at the first hit:
   - the current branch name, matched against the configured key pattern
     (`CLAUDE_TICKET_PATTERN`, default `[A-Z][A-Z0-9]+-[0-9]+`);
   - the user's message;
   - earlier context in this session.

2. **Fetch the item** from the tracker. Do not work from the key alone — a key
   proves someone typed a string, not that an item exists behind it.

3. **Show what you found**, in one line, before doing anything else:

   ```
   [PROJ-123] Async intake pipeline — Status: In Progress — Assignee: <name>
   ```

4. **Check the four properties.** Each failure blocks; see the table below.

   | Property | Passing means | On failure |
   | --- | --- | --- |
   | Exists | The tracker returns the item. | Stop. Ask which item this work attaches to. |
   | Assigned | It has an assignee, and that assignee is whoever is doing the work. | Stop. Assign it, or confirm you are working on someone else's item deliberately. |
   | Workable state | It is in a state that means work may start (see `status-vocabulary`). | Move it to the in-progress state first, with a comment. Never work silently against a backlog item. |
   | Parented | It has a live parent, unless it is itself a top-level item (see `parent-child-hygiene`). | Set a parent before continuing. |

5. **Validate scope.** Compare what the item describes with what was asked. If the
   request falls outside the item's description, say so and offer the choice —
   a new item, or an explicit widening of this one. Do not silently expand scope:
   that is how one item's history ends up describing three changes.

6. **No key found?** Ask. Do not invent one, do not proceed "just this once", and
   do not attach the work to the nearest plausible item without confirmation.

## Worked example

> **User:** Add retry logic to the ingestion worker.

The message carries no key, so check the branch:

```
$ git branch --show-current
feature/PROJ-123-async-intake-pipeline
```

`PROJ-123` matches the configured pattern. Fetch it:

```
[PROJ-123] Async intake pipeline — Status: In Progress — Assignee: <name>
```

Exists, assigned, workable, parented — but the scope check fails. Retry logic in
the ingestion worker is not the async intake pipeline. Respond:

> This branch is for PROJ-123 (async intake pipeline). Retry logic in the
> ingestion worker looks outside that scope. Should I open a separate item for it,
> or does it belong under PROJ-123 after all?

Then wait. The scope question is the point of the gate — answering it yourself is
the failure this procedure exists to prevent.

## Why it blocks rather than warns

A warning that work is untracked is read after the work exists, when the cost of
correcting it is a retroactive item written from memory. A block is read before,
when the correction is one question. The gate is only worth having in the
blocking form.
