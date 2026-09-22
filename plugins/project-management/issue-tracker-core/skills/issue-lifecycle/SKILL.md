---
name: issue-lifecycle
license: MIT
description: Comment on the item when you start, when you hand off or pause, and when you finish, because the tracker is the durable record of the work and the chat session is not. Use when beginning work, at a significant checkpoint, when opening a pull request, when stopping mid-stream, and when a change merges.
---

# Issue Lifecycle

The item is the record that outlives the session. A conversation, a terminal
scrollback and an agent's context all vanish; the comment thread on the item is
what a reader has in six months when they ask why the code looks like this.

Write for that reader. They have the diff already — give them the reasoning the
diff cannot carry.

## The three mandatory comments

| Moment | Comment contains |
| --- | --- |
| **Start** | The approach you intend to take, anything the item's description got wrong, and the branch name. |
| **Handoff / pause** | Exactly where things stand, what is known-broken, and the single next step. |
| **Finish** | The link to the merged change and confirmation that acceptance is met. |

Pair each with the corresponding state move from `status-vocabulary` — the
comment explains the move, the move makes it findable.

## Also worth a comment

- A decision that changes the approach mid-stream, with the reason.
- A discovery that invalidates part of the item's description.
- A blocker: what is blocking, who or what unblocks it, when it started.
- A scope negotiation and its outcome — the "we agreed to leave X out" that
  someone will otherwise re-litigate in review.

## Not worth a comment

Routine progress noise. "Still working on this" adds nothing and trains readers
to skim the thread, which is how a real comment gets missed. If nothing has
changed except elapsed time, say nothing.

## What a good comment looks like

**Start:**

> Starting on `feature/PROJ-123-add-auth-middleware`. Plan: middleware wrapping
> the existing session lookup, so no call sites change. The description assumes a
> shared token cache — there isn't one yet, so this adds an in-process cache and
> leaves the shared one for a follow-up.

**Handoff:**

> Pausing here. Middleware is written and unit-tested; the integration test
> against the staging directory fails on expired fixtures, which is unrelated to
> this change. Next step: refresh the fixtures, then open the pull request.

**Finish:**

> Merged in <link>. Acceptance criteria 1-3 verified in the integration suite.
> Criterion 4 (shared token cache) was split out as agreed — see PROJ-456.

Each is short, and each tells a future reader something the code does not.

## Why chat does not count

An explanation given in a session is not a record. It has no URL, no ordering
relative to the change, and no reader other than the person who was present. Two
consequences follow:

- Anything a reviewer needs goes on the item **before** review starts, not in a
  reply to whoever asks.
- Anything the next person needs goes on the item **before** you stop, because
  "I'll write it up later" competes with whatever you do next.

## Verify what automation claimed

When a command, hook or agent was supposed to post a comment or advance a state,
read the item back and confirm it happened. A silent failure here leaves an item
whose thread asserts nothing and whose state asserts something false — and the
whole point of the record is that it can be trusted without re-checking.
