---
name: status-vocabulary
license: MIT
description: A generic issue lifecycle — backlog, ready, in progress, in review, done, plus parked and declined — with the entry condition each state asserts and what must be true before an item may advance. Use when deciding whether to move an item's state, when a state looks wrong, or when mapping a tracker's own workflow onto a shared vocabulary.
---

# Status Vocabulary

A state is a **claim about reality**, made to people who will not verify it. "In
review" tells the team a reviewable artefact exists. "Done" tells them the change
is merged. A state that outruns the truth is worse than no state, because it is
trusted and acted on.

This skill defines the states and their entry conditions. It deliberately defines
no transition identifiers, workflow IDs or API mechanics — an adapter maps these
names onto whatever the tracker calls them.

## The states

| State | It claims | Entry condition — all must hold |
| --- | --- | --- |
| **Backlog** | Captured, not yet prioritised. | The item is written well enough that someone else could pick it up and ask the right questions. |
| **Ready** | Prioritised and startable. | Scope is understood, it has a parent, dependencies are unblocked, acceptance is stated. |
| **In progress** | Someone is actively working it now. | It is assigned, and work has actually begun — including research, exploration or branch creation. |
| **In review** | Awaiting judgement by someone else. | A reviewable artefact exists and is linked from the item. Checks are green, or their failure is explained on the item. |
| **Done** | Finished and integrated. | The change is merged (or the decision is recorded, for non-code items), and acceptance is met. |
| **Parked** | Deliberately deferred. | A reason is recorded, and a condition for revisiting is named. |
| **Declined** | Deliberately not done. | A reason is recorded. The item stays for the record; it is not deleted. |

## The happy path

```
Backlog -> Ready -> In progress -> In review -> Done
```

Two legitimate departures from it:

- **Review rejection returns the item to in progress.** It does not stay in
  review while rework happens — that state is claiming a reviewer is waiting.
- **Blocked work returns to ready or parked**, with the blocker named. Leaving an
  item in progress for a week while it is blocked on someone else makes the
  in-progress list useless for the one purpose it has.

Skipping forward is rarer than it looks. An item that goes backlog → done had
either no work in it or untracked work in it, and both are worth noticing.

## Rules

1. **Move the state when the thing happens, not at the end of the day.** Enter
   in progress the moment work starts, including exploratory reading of the
   codebase. Enter in review as the pull request is opened, not after it merges.
2. **Never invent a state name.** If the tracker's workflow has no equivalent for
   one of these, map it to the nearest state and say so in the adapter — do not
   add a sixth state locally.
3. **One item, one state.** An item that is "in progress and also in review" is
   two items.
4. **Do not use done as a filing cabinet.** Work abandoned rather than finished is
   parked or declined. Done means integrated; a false done is invisible after a
   week because nobody re-reads closed items.
5. **Verify after moving.** If a skill, hook or automation was supposed to advance
   the state, read it back. An unreported failed transition leaves the item lying
   to the team.

## Mapping a tracker's workflow

Most trackers ship more states than this, or fewer. The mapping is per-repo and
belongs in the adapter, not here. What must survive the mapping:

- Exactly one state means "work has begun".
- Exactly one state means "waiting on a reviewer".
- Terminal states distinguish **finished** from **abandoned**. Collapsing those two
  destroys the only signal that tells you whether the backlog is shrinking because
  work is landing or because work is being dropped.
