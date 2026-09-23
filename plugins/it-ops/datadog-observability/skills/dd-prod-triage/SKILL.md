---
name: dd-prod-triage
description: "Sweep a window of Datadog production errors into a ranked, deduplicated proposal set. Aggregate before reading, rank by blast radius and novelty rather than raw count, collapse issues that share one fault, and hand back proposals. Use for 'what is broken in this Datadog org', a scheduled error review, or a post-incident sweep. The Datadog execution of observability-core's production-triage skill."
license: MIT
---

# Datadog production triage

`observability-core`'s `production-triage` states the discipline: **aggregate
before you read, rank by blast radius and novelty, and only then decide what
becomes tracked work.** This is that procedure against Datadog.

It produces a **proposal set** and stops. Filing is a tracker adapter's job — see
"The handoff" below, and read it before wiring this to anything.

## Phase 1 — aggregate. Do not read events yet.

Error Tracking has already done the clustering. Start from issues, not from logs:

```
POST https://api.<SITE>/api/v2/error-tracking/issues/search
{ "data": { "attributes": {
    "from": <unix_ms>, "to": <unix_ms>,
    "query": "service:<SERVICE> env:<ENV>",
    "track": "trace" } } }
```

Each issue carries what you triage on: **total count, affected-user count,
first-seen, last-seen, state, and a representative stack trace.** The
representative is usually enough — it is what lets you skip reading raw events
for most issues entirely.

For a service that does not report into Error Tracking, fall back to a log
aggregation grouped by `@error.type` or `@error.stack` — the `analytics/aggregate`
call in `datadog-monitors-and-queries`. **Record in your output which issues came
from Error Tracking and which from a log grouping**, because a hand-grouped
cluster is a weaker claim than a clustered issue and a reader needs to know which
they are looking at.

**The mistake this phase prevents:** opening the log explorer and reading errors
newest-first. That surfaces the loudest recent thing, which correlates with
neither impact nor novelty, and it burns the window you had.

## Phase 2 — rank. Raw count is the weakest signal you have.

`observability-core` says impact sets severity. Applied to a sweep:

| Rank by | Why it beats count |
|---|---|
| **Affected users** | 40,000 errors from one retry loop on one tenant is one bad tenant. 400 errors across 400 users is an outage. |
| **Novelty** | A brand-new issue with 40 events usually outranks a known issue with 4,000. The known one has been surviving; the new one is a change that just landed. |
| **First-seen against deploys** | An issue whose `first_seen` sits just after a `version` change has a named suspect. |
| **Trajectory** | Rising beats flat at the same count. Flat-and-large is debt; rising-and-small is an incident forming. |
| **Silence** | A service that *stopped* erroring because it stopped serving produces no issue at all. Check request-rate alongside; see below. |

**Raw count ranks last**, and a sweep that sorts by it will spend its attention
on a noisy logger.

### The absent signal

Nothing in an error sweep will show you a service that went quiet. Before
reporting a window as triaged, look at request rate across the services in scope
— a service at zero traffic is the most serious thing a sweep can find, and it is
invisible to every query above.

## Phase 3 — deduplicate

Distinct issues are routinely one fault:

- **Same root, different frames.** One failure surfacing through three call
  paths. The bottom of the stack matches; the top does not.
- **Same fault, different services.** A dependency failing produces an issue in
  every caller. The timeline is the tell: they start within seconds.
- **Wrapped exceptions.** The same cause re-raised with a different type at each
  boundary.
- **A retry loop.** One logical failure, N logged errors. Count per *user* rather
  than per event and it collapses.

Merge into one proposal naming the surfaces, rather than filing N items someone
later closes as duplicates. Where you are unsure, keep them separate and say why
— a wrong merge hides a real second fault.

## Phase 4 — the proposal set

One entry per surviving cluster. Each **must** carry:

- a link to the Error Tracking issue or the saved log query
- first-seen and last-seen, and whether it is rising, flat or decaying
- total count **and** affected-user count, stated separately
- the deploy or config change it correlates with, or explicitly *none found*
- which services it surfaces in
- the representative stack trace, or a short quotation from it
- **whether it came from Error Tracking or a hand-grouped log query**

And, per `observability-core`, **what you could not determine.** An issue with no
affected-user count because the service does not report user context is a known
unknown; reporting it as zero users is a wrong answer that looks complete.

## Phase 5 — muting and resolving need a written reason

`PUT /api/v2/error-tracking/issues/<id>/assignee`, and the state transitions to
`RESOLVED` or `IGNORED`, are real mutations. Neither belongs in an unattended
sweep.

Resolving an issue that recurs re-opens it, which is fine. **Muting is the
dangerous one** — a muted issue stops appearing in exactly the sweep that would
have caught it growing. Mute only with a stated reason and a date to revisit, and
record both in the proposal set so the decision is auditable. "It was noisy" is
not a reason; "it is a known third-party timeout tracked in <item>, revisit after
their fix ships" is.

## The handoff

This skill stops at proposals **deliberately**. Filing into a tracker requires
knowing a project, a work-item type and a field layout — all of which belong to a
tracker adapter and none of which belong here. The employer implementation this
was generalised from filed straight into one hardcoded tracker instance, which is
precisely the coupling this marketplace is organised to avoid: it made an
observability tool unusable for anyone with a different tracker.

Pair with `jira-tracker` or `github-issues`. Each proposal above carries what
either needs; the tracker adapter owns the create call.

## Not this skill's job

- **Deciding whether to declare an incident.** That is `observability-core`'s
  `incident-declaration`, and a triage sweep that finds a live outage should stop
  and declare rather than finish the sweep.
- **The postmortem.** `incident-postmortem` in `ops-workflows`.
- **Fixing anything.** A sweep that starts editing code has stopped being a sweep.
