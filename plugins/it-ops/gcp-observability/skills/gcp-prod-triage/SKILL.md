---
name: gcp-prod-triage
description: "Sweep a window of GCP production errors with Cloud Error Reporting, aggregate before reading, rank by blast radius and novelty, dedupe, and produce a proposal set of tracked work items. Use for 'what is broken in this GCP project', a scheduled error review, or a post-incident sweep. The GCP execution of observability-core's production-triage skill."
license: MIT
---

# GCP Production Triage

`observability-core`'s `production-triage` defines the loop: **aggregate first, read
second, propose third, write last.** Read it for the judgement. This skill is the GCP
execution of it, and the whole reason it exists is one mistake that GCP makes very easy to
make.

## The mistake this skill prevents

Error Reporting exposes two things that look interchangeable and are not:

| Endpoint | Returns | Use |
|----------|---------|-----|
| `projects.groupStats.list` | **Aggregates.** One row per error group: count, affected-user count, first-seen, last-seen, affected services, one representative event. | **Always start here.** |
| `projects.events.list` | **Raw events.** Individual occurrences, one row each, unbounded in the general case. | Only after ranking, and only for the top few groups, to confirm a signature is what it claims. |

Opening `events.list` first is the failure this skill exists to prevent. It is slow, it
buries the finding under thousands of near-identical rows, and — the part that actually
costs you — it silently reorders your attention by volume. The loudest group is rarely the
worst one, and a raw event list has no way to tell you that.

`groupStats` is the aggregate endpoint. `events` is the raw one. Start with the aggregate.

## Phase 1 — Aggregate

```
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://clouderrorreporting.googleapis.com/v1beta1/projects/<PROJECT_ID>/groupStats?\
timeRange.period=PERIOD_1_DAY\
&order=COUNT_DESC\
&alignment=ALIGNMENT_EQUAL_ROUNDED\
&pageSize=30"
```

| Parameter | Values | Notes |
|-----------|--------|-------|
| `timeRange.period` | `PERIOD_1_HOUR`, `PERIOD_6_HOURS`, `PERIOD_1_DAY`, `PERIOD_1_WEEK`, `PERIOD_30_DAYS` | Coarse buckets only — there is no arbitrary start/end here. Pick the smallest that covers your window. |
| `order` | `COUNT_DESC`, `LAST_SEEN_DESC`, `CREATED_DESC`, `AFFECTED_USERS_DESC` | Run it **twice**: once `COUNT_DESC`, once `CREATED_DESC`. The second is your novelty list and it is usually the more valuable of the two. |
| `alignment` | `ALIGNMENT_EQUAL_ROUNDED`, `ALIGNMENT_EQUAL_AT_END` | Controls how the `timedCounts` buckets line up. `ALIGNMENT_EQUAL_AT_END` ends the last bucket at now, which is what you want for a trend read during an incident. |
| `timedCountDuration` | e.g. `3600s` | Bucket width for `timedCounts`. Set it to get a trajectory rather than a single total. |
| `serviceFilter.service` | a service name | Scope the sweep to one service. |
| `pageSize` / `pageToken` | | Page rather than raising `pageSize` without limit. |

Each `ErrorGroupStats` row carries the fields you actually triage on: `count`,
`affectedUsersCount`, `firstSeenTime`, `lastSeenTime`, `affectedServices`,
`numAffectedServices`, `timedCounts`, and `representative` (one sample event, including
its stack trace). **The representative event is usually enough — it is what lets you skip
`events.list` entirely for most groups.**

### There is no `gcloud` read path for Error Reporting. At all.

Verified against Google Cloud SDK 586.0.0 and the command reference on 2026-09-22:
`gcloud beta error-reporting` exposes exactly two commands, and neither of them reads.

| Command | What it does |
| --- | --- |
| `gcloud beta error-reporting events report` | Writes one error event. |
| `gcloud beta error-reporting events delete` | **Destructive.** Deletes *all* error events in the project. |

There is no `events list`, no `groups` group, and no `groupStats` surface. If you reached
for a `gcloud` command to read errors and it appeared to work, check what you actually
ran — the only near-miss in this command group destroys the data you were trying to read.

**So the API is not the advanced path here; it is the only path.** Use `curl` against
`projects.groupStats.list` for Phase 1, as above.

The same holds for Cloud Monitoring, and for the same reason. `gcloud monitoring` manages
dashboards, alerting policies, snoozes and uptime checks — verified, it has no group for
reading time series. Every metrics example in this plugin goes through
`projects.timeSeries.list` over `curl` because no CLI alternative exists to prefer.

### When a service is not in Error Reporting at all

Error Reporting only sees what is reported to it — either through the client libraries or
through log entries in the shape it recognises. A service that logs plain strings, or a
managed component that only exposes counters, is invisible here.

For those, cluster from Cloud Logging instead (see `gcp-log-queries`) or from a
Monitoring counter, and **record in your output that the cluster came from logs or from a
metric, not from Error Reporting**. The core's rule: never report a gap as a clean result.
"Nothing in Error Reporting" is a statement about Error Reporting, not about production.

## Phase 2 — Rank by blast radius and novelty, not by count

Count is where the list arrives sorted. It is not the ordering you report.

**A new group with 40 events usually outranks a known group with 4,000.** Four thousand
events from a group first seen eight months ago is the cost of doing business, already
absorbed, probably already ticketed. Forty events from a group first seen ninety minutes
ago is a regression that is still arriving — and if its `firstSeenTime` sits just after a
build finished, it is the highest-value row in the sweep.

Rank with these, in this order:

1. **Novelty.** `firstSeenTime` inside the window, or a `timedCounts` series that stepped
   up sharply. Cross-reference against `gcloud builds list` and the audit log — see
   `gcp-incident-response` Step 3.
2. **Blast radius.** `affectedUsersCount` over `count`. A group with `count: 4000,
   affectedUsersCount: 1` is one client in a retry loop; the honest population is one.
   The reverse — `count: 40, affectedUsersCount: 38` — is 38 people having a bad day.
3. **Trajectory.** From `timedCounts`: growing beats flat beats recovering.
4. **Failure mode severity.** Data loss, authorization failures and silent wrong answers
   outrank retriable transport errors at equal volume.
5. **Breadth.** `numAffectedServices` greater than one suggests a shared dependency rather
   than a service bug, which changes who owns the fix.

**`affectedUsersCount: 0` means not measured, not nobody.** Error Reporting counts
distinct users only where the reported error carried a user identifier. If your services
do not populate it, the field is zero for every group and is worthless for ranking — say
so once, out loud, and rank on the other dimensions instead of quietly treating zero as a
measurement.

Only after ranking, read the `representative` event for the top groups, and drop to
`events.list` only where the representative is ambiguous.

## Phase 3 — Deduplicate

Distinct Error Reporting groups are frequently the same underlying fault. Error Reporting
groups on the exception type and stack trace shape, which splits on things that do not
matter and joins on things that sometimes do. Watch for:

- **The same exception from two services either side of a call.** A timeout group in the
  caller and a connection-reset group in the callee are one fault. `affectedServices` on
  each row is the tell.
- **One fault after a refactor.** A deploy that moved a function changes the stack frames,
  so the same bug appears as a new group with the old one going quiet at the same minute.
  Matching `lastSeenTime` on the old and `firstSeenTime` on the new is the signature.
- **Wrapped versus unwrapped.** The same root error surfacing raw on one path and wrapped
  in an application exception on another.
- **Retry amplification.** One user action producing a group per attempt, sometimes with
  different exception types per layer.
- **Per-revision splits.** The same fault reported separately across revisions deployed
  during the window.

Merge them, present the merged cluster once, and **state the merge** so the numbers stay
reproducible by anyone re-running your queries.

Then dedupe against existing work: search the tracker for each surviving cluster before
proposing anything new, on the service name, the exception class, and the user-visible
symptom — the existing ticket was filed in different words than Error Reporting's
signature produces. Mark each cluster **NEW** or **DUPLICATE → existing item**.

## Phase 4 — Propose, and stop

**This skill produces a proposal set. It does not file anything.** Creating tracker items
belongs to a tracker adapter plugin, behind the core's approval gate. Filing from here
would bypass both the human choice and the tracker's own conventions.

Present the ranked table first:

```
#  Service        Group signature                  Count  Users  First seen  Trend      Source
1  <SERVICE-A>    TimeoutError @ PaymentClient       142     98   2h ago     growing    error-reporting
2  <SERVICE-B>    GET /suggest -> 500                 38     31   18h ago    flat       error-reporting
3  <SERVICE-C>    job failure counter                 11      ?   40m ago    new        metric
```

Then, for each NEW cluster, the item you propose, containing all of:

- **Group link** — the Error Reporting console URL for the group, so the reader can open
  the live view rather than trust a snapshot. Include the group id.
- **First seen** and **last seen**, as timestamps, not "2h ago".
- **Count** over the stated window, with the window stated.
- **Affected-user count**, or an explicit `not measured — no user identifier reported`.
- **Deploy correlation** — the build, rollout, revision or audit-log entry nearest the
  first-seen time, or an explicit "no change found within N minutes". A cluster with no
  correlation is a finding too; say you looked.
- **The exact queries you ran**, so the numbers are reproducible.
- **The representative stack trace**, trimmed to the application frames.

State the noise floor you applied and how many clusters it removed. Silently truncating is
how a low-count, high-blast-radius cluster disappears.

If any cluster reflects **current, confirmed production impact**, stop triaging and
declare — `incident-declaration` in `observability-core`, executed via
`gcp-incident-response`. Triage finds work; it is not a substitute for declaring.

## Muting and resolving a group

Error Reporting groups carry a `resolutionStatus` (`OPEN`, `ACKNOWLEDGED`, `RESOLVED`,
`MUTED`), settable through the console or `projects.groups.update`.

**This is a mutation and it is outside the read-only part of triage.** It is also the one
action in this skill that destroys future signal: a muted group stops competing for
attention in every later sweep, including the one where it comes back for a different
reason.

So: never mute as a way of tidying a list, and **never mute without a written reason
recorded somewhere that outlives the session** — the tracker item, or the group's own
history. The reason must say what was decided and what would make it wrong. Compare:

- Acceptable: *"Muted. Known third-party client sending malformed requests on a deprecated
  endpoint; endpoint removal tracked in <ITEM>. Unmute if the count exceeds 500/day or if
  it appears on any other endpoint."*
- Not acceptable: *"Noise."*

Prefer `RESOLVED` over `MUTED` when a fix actually shipped: a resolved group that recurs
reopens and becomes visible again, which is exactly the behaviour you want. `MUTED` is for
a fault you have consciously decided to keep living with, and it should be rare enough
that each one is memorable.

## Guardrails

- Aggregate before you read. `groupStats` before `events`, every time.
- Bound every window. `timeRange.period` on the API, `--freshness` and `--limit` on any
  Logging read.
- Read-only throughout. No muting, no resolving, no metric creation, no filing.
- Never report a gap as a clean result. Name the services not covered by Error Reporting
  and where their data actually lives.
- Zero affected users is a missing measurement until you have confirmed the field is
  populated.
