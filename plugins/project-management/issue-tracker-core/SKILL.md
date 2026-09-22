---
name: issue-tracker-core
license: MIT
description: Tracker-neutral discipline for working against an issue tracker — the gate that requires a real, scoped, assigned issue before any code is written, branch and title conventions that keep the issue key discoverable, a generic lifecycle vocabulary, parent-child hygiene, and the rule that the issue (not the chat) is the durable record. Use when starting work on an issue, naming a branch or pull request, deciding when to move an item's state, or triaging items with no parent.
---

# Issue Tracker Core

The parts of issue-tracker practice that hold no matter which product hosts the
tracker. Nothing here names a tracker vendor, an issue-type ID, a transition ID,
a workflow ID or a project key. Those belong to an adapter layer built on top of
this one.

Read an adapter for the API calls. Read this for what the calls are *for*.

## Skills

| Skill | Use it when |
| --- | --- |
| `pre-work-gate` | About to write, edit, refactor or branch — before the first line of code. |
| `branch-and-title-conventions` | Creating a branch, a worktree, a commit scope or a pull request title. |
| `status-vocabulary` | Deciding whether an item may advance, and what its state is claiming. |
| `parent-child-hygiene` | Creating an item, or auditing a backlog for orphans. |
| `issue-lifecycle` | Starting work, handing off, pausing, or finishing — the comment trail. |

## The four claims that tie them together

1. **Work without an issue is untracked work.** Code that exists with no item
   behind it cannot be prioritised, reviewed against intent, or explained later.
   The gate exists to make that state unreachable, not merely discouraged.

2. **The branch is the carrier.** If the issue key is recoverable from the branch
   name, every downstream artefact — commit scope, pull request title, changelog
   line, release note — can be derived mechanically instead of remembered.

3. **A state is a claim about reality.** "In review" means a reviewable artefact
   exists. "Done" means it is merged. A state that is not backed by the thing it
   claims is worse than no state at all, because it is trusted.

4. **The tracker is the durable record; the chat is not.** Reasoning that lives
   only in a conversation is lost the moment the session closes. Anything a future
   reader needs goes in a comment on the item.

## What this plugin deliberately leaves out

- Endpoint names, authentication, and API payload shapes.
- Numeric issue-type, status or transition identifiers.
- A project key, a board ID, or any account identifier.
- Cached inventories of parents, components or sprints — see
  `parent-child-hygiene` for why a live query replaces them.

An adapter supplies all of the above. If you find yourself wanting to hardcode
one of them here, that is the signal you are writing the adapter.

## Configuration

One convention is shared with the sibling `dev-guardrails` plugin so the two
agree about what an issue key looks like:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Regex for the issue-key shape used to recognise a key in a branch name, message or title. |

Set it per repo when the tracker uses a different key shape (for example
`ISSUE_[0-9]+` or a bare numeric ID). Every skill here refers to "the configured
key pattern" rather than restating a literal.
