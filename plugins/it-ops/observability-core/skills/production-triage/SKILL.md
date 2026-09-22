---
name: production-triage
description: "Sweep a window of production errors, cluster them by signature, dedupe against existing tickets, rank by blast radius and novelty, and propose tracked work items — writing nothing until approved. Use for 'what's broken in prod', scheduled error review, post-incident sweeps, or converting an error backlog into owned tickets. Vendor-neutral: describes the queries abstractly for any error aggregator."
license: MIT
---

# Production Triage

A repeatable loop that turns a window of production errors into a short, ranked list of
things worth doing — and nothing else. The loop is **aggregate first, read second,
propose third, write last.** It is deliberately read-only until a human approves the set
of work items to create.

This skill describes telemetry access as capabilities. Wherever it says *query your error
aggregator*, use whatever you run: a hosted APM's grouping view, a log platform's
aggregation query, a cloud provider's metric filters, or `grep | sed | sort | uniq -c`
over a log archive. The discipline is identical; only the syntax changes.

## Inputs

- **Scope** — one service, a named set, or everything. Default: everything in the
  production environment.
- **Window** — the time range. Default: the last 24 hours. Use a shorter window for a
  live incident, longer for a scheduled review.
- **Environment tag** — confirm the exact literal your stack uses for production before
  querying. A near-miss on the tag value returns zero rows and looks identical to a clean
  system; verify the tag returns *some* data before concluding anything is healthy.

## Phase 1 — Aggregate, never enumerate

**Ask for counts before you ask for records.** A window of production errors can be
millions of lines; pulling them is slow, expensive, and buries the finding.

Query your error aggregator for the window, filtered to production and error-level
severity, **grouped by error signature**, returning counts per group, ordered descending.
For each group also capture first-seen, last-seen, and no more than three to five sample
records for later reading.

An **error signature** is the most stable identifier available, in this order of
preference:

1. An explicit error type or event-type field, if your services emit one.
2. Exception class plus the top application frame of the stack trace — skipping framework
   and runtime frames, which are identical across unrelated bugs.
3. The operation identity: endpoint or route plus status code, or job name plus failure
   mode.
4. The message text with variable parts normalized away — numbers, UUIDs, emails, paths,
   timestamps replaced by placeholders. Without normalization every error is unique and
   nothing clusters.

**Where errors are not searchable as text** — a component whose logs go somewhere your
aggregator cannot reach, or a managed runtime that only exposes counters — cluster on the
error *metric* for that component instead, and record in the output that the cluster came
from a counter, not from log lines. Never report that you searched logs you cannot reach;
name the gap and point at where those logs actually live.

## Phase 2 — Cluster, dedupe, rank

**Merge.** Combine groups that are the same underlying fault under different signatures:
the same exception from two instances of one service, one fault surfacing as both a
timeout upstream and a connection reset downstream, retry storms that produce N errors per
user action. Collapse those and note the merge; do not present the same bug three times.

**Apply a noise floor, out loud.** Drop clusters below a count threshold over the window
— unless the sweep was scoped to a single service, where surfacing everything is the
point. Always state the floor and how many clusters it removed. Silently truncating is
how a low-count, high-severity cluster disappears.

**Rank by impact, not by count.** Count is the starting point, not the ordering. Adjust
with:

- **Blast radius** — distinct users or tenants affected, and the failure share of the
  affected path. Use the `blast-radius` skill's dimensions. A cluster with 40 events
  across 40 customers outranks one with 4,000 events from a single looping client.
- **Novelty** — is this new in this window, or has it been steady for months? New
  clusters, and old clusters whose rate just changed, rank above flat background noise. A
  cluster that appeared right after a deploy is the highest-value finding in any sweep.
- **Trajectory** — growing beats flat beats recovering.
- **Severity of the failure mode** — data loss, auth or authorization failures, and
  silent wrong answers outrank retriable transport errors at the same volume.

Only after ranking, read the three-to-five saved samples for the top clusters to confirm
each is what its signature suggests.

Present the ranked table before proposing anything:

```
#  Service            Signature                       Count  Users  Trend     First seen   Source
1  checkout-api       TimeoutError @ PaymentClient      142     98  growing   2h ago       logs
2  search-service     GET /suggest → 500                 38     31  flat      18h ago      traces
3  export-worker      job failure counter                11      ?  new       40m ago      metric
```

## Phase 3 — Dedupe against existing work

For every cluster above the floor, search the work tracker for an open item covering it
**before** proposing a new one. Search on the service name, the signature, and the
user-visible symptom — the existing ticket was probably filed with different wording than
your signature produced.

Mark each cluster **NEW** or **DUPLICATE → <existing item>**. For duplicates, offer to add
a comment recording the recurrence with a fresh count and window rather than filing again.
A recurrence comment on a stale ticket is often more valuable than a new ticket, because
it converts "reported once" into "still happening, at this rate."

## Phase 4 — Propose, and stop

**Write nothing yet.** Present the NEW clusters as an explicit multi-select and let the
user choose which become tracked items. Show the fields you intend to use for each:

- **Title** — `[prod] <service>: <signature> (<count> in <window>)`
- **Body** — count, distinct users, first/last seen, the trend, the exact query used so
  someone can re-run it, the sample records, and for counter-derived clusters, where the
  real logs live.
- **Parent / component / labels** — per your tracker's conventions, confirmed per item
  rather than assumed. Do not invent a parent, an epic or a status value; use the ones
  that exist.
- **Owner** — per your team's convention. New items land in the default intake state; do
  not auto-transition them into an active state, which is the owner's call.

If any proposed cluster reflects **current, confirmed production impact**, stop triaging
and declare an incident first — see the `incident-declaration` skill. Triage is the
mechanism for finding work; it is not a substitute for declaring.

## Phase 5 — File approved, then report

Create only the approved items. Comment on the duplicates the user chose to annotate.
Then report one table mapping every cluster to its outcome: new item + link, commented +
link, or skipped with the reason. The skipped rows matter — they are the record of what
was seen and consciously not acted on, which is what stops the next sweep from
re-litigating the same noise.

## Guardrails

- **Read-only until the approval gate.** Phases 1–3 only read. The only writes happen in
  Phase 5.
- **Aggregate-first, always.** Counts before records; at most five raw samples per
  cluster; the tightest window that answers the question.
- **Never report a gap as a clean result.** If a component's errors are not reachable from
  your aggregator, say which component and where its data lives. Zero rows from a query
  you could not run correctly is not zero errors.
- **Never invent tracker vocabulary.** Parents, statuses, components and labels come from
  the live tracker, not from memory of what they were last quarter.
- **State the noise floor and the merges.** Every number you present should be
  reproducible by someone re-running the query you printed.
