---
name: parent-child-hygiene
license: MIT
description: Every tracked item belongs under a live parent; the list of candidate parents is a query run each time, never a cached table; and an orphan is a defect to be fixed, not a style preference. Use when creating an item, when an item has no parent or a closed one, or when auditing a backlog for orphans.
---

# Parent-Child Hygiene

Three rules, in order of how often they are broken:

1. **Every non-top-level item has a parent.** No exceptions granted case by case.
2. **The candidate-parent list is a query, not a table.** Run it every time.
3. **An orphan is a defect.** It is fixed when found, not noted and left.

## Why a parent at all

The parent is what makes a body of work legible above the level of individual
items. Without it you can answer "what is open" and cannot answer "what are we
actually doing" — and the second question is the one that gets asked in planning.

An orphaned item is also unfindable. It does not appear in a rollup, it is not
counted against an initiative, and it survives every prioritisation pass by being
invisible to all of them.

## The parent list is a QUERY, not a table

Do not cache a list of candidate parents in a skill, a config file or a memory
note. Parents open, close and get renamed constantly — a cached list is wrong
within weeks and, worse, is *trusted* while wrong.

A staleness note ("re-check if older than 30 days") does not fix this. It makes
the staleness documented, which is a different thing: checking the date is a step,
and skipping a step is free. The predictable end state is a gate that has been
reading an expired table as authoritative for months, pointing work at parents
that closed long ago.

Instead, run a two-stage query.

**Stage 1 — the shortlist.** Narrow to the parents that are right for most work
(current time-boxed buckets, platform and infrastructure buckets, whatever your
board's equivalent is). It must be short enough to present as an actual choice —
five to ten entries.

**Stage 2 — the full set.** Only when nothing in the shortlist fits. Unfiltered
except for liveness.

Why two stages: a list of eighty candidates is not a choice. An instruction to
"present the list" that cannot be followed is an instruction that gets skipped,
and the skipped version of this instruction is an orphan.

## Liveness is part of the query

Filter on the **state category**, not on a single state name. Most trackers have
more than one terminal state — finished, abandoned, deferred — and a filter that
excludes only the literal "done" one lets the others through.

Exclude explicitly:

- finished parents,
- declined parents,
- parked or deferred parents.

None of those is ever a valid parent. Most trackers will accept one anyway,
silently — no error, no warning — and the new item lands under something nobody
reads again. **Verify the state of the parent you got back** rather than assuming
the filter did its job.

## An existing parent can still be wrong

An item carrying a parent reference reads as compliant and may not be. If the
parent is finished, declined or parked, treat the item as orphaned and re-parent
it. This is the failure mode that survives every "does it have a parent" check
ever written, because the answer is technically yes.

## Procedure when creating an item

1. Decide whether the new item is itself top level. Top-level items are the only
   ones exempt from parenting — and creating one is a planning decision, so
   **never create a top-level item without explicit human approval.**
2. Otherwise run the stage-1 query.
3. Present the shortlist, or propose one candidate from context and say why.
4. If nothing fits, run stage 2. If nothing there fits either, ask whether a new
   top-level item is warranted — and wait for the answer.
5. Set the parent as part of creating the item, not as a follow-up. A follow-up
   step is the step that does not happen.

## Auditing for orphans

Run periodically, and as part of the pre-work gate for the single item in hand:

- items with no parent reference;
- items whose parent is in a terminal or deferred state;
- items whose parent no longer exists.

All three are the same defect with different spellings. Fix them the same way.
