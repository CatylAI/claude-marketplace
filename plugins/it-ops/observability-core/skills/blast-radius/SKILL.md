---
name: blast-radius
description: "Establish how many users, requests, tenants and regions an incident actually affects, before choosing a response. Use when severity must be set or challenged, when someone asks 'how bad is this?', when an error's importance is unclear, or when a stack trace looks alarming but impact is unmeasured. Vendor-neutral — works with any metrics or logging stack."
license: MIT
---

# Blast Radius

**Blast radius is the measured size of the affected population.** It is the input to
severity, to paging, to customer communication, and to whether an error found in triage
deserves a ticket at all. It is a number with units, produced before the response posture
is chosen — not an impression formed after reading a stack trace.

## Why the stack trace does not set severity

A stack trace tells you *what broke and where*. It tells you nothing about *how many
people it broke for*. These come apart constantly and in both directions:

- A dramatic `NullPointerException` deep in a core service, firing on an
  admin-only endpoint used twice a week, is a Sev3 at most.
- A bland `connection reset` in a retry wrapper, silently failing 4% of checkouts in
  one region, is a Sev1.

Responding to the trace instead of the number produces two predictable failures: the
alarming-but-narrow bug pulls responders off the quiet-but-broad one, and the quiet
breadth goes unnoticed because nothing in the trace looked frightening. Severity by
impact is what keeps attention proportional to harm.

The trace earns its keep later — it drives the *fix*. It does not drive the *response*.

## The five dimensions to measure

Measure each one, with a number and a unit. "Some users" is not a measurement.

1. **Users / accounts.** Distinct identities that hit the failure, as a count and as a
   share of active users in the window. Distinct counts matter more than event counts:
   ten thousand errors from one retry-looping client is a different incident from ten
   thousand errors across ten thousand people.
2. **Requests / operations.** Failed operations as a share of total attempts on the
   affected path. This is the error *rate*, and it is what tells you whether the path is
   broken or merely lossy.
3. **Tenants / segments.** Which customers, plans or cohorts. One enterprise tenant fully
   broken may outrank a thin slice spread across the long tail, and the reverse is also
   sometimes true — say which cohort, do not just count heads.
4. **Geography / infrastructure scope.** Regions, availability zones, clusters, or
   deployment shards affected. Single-zone versus all-zones is often the difference
   between a degradation and an outage, and it narrows the cause dramatically.
5. **Time.** When impact started (not when the alert fired, and not when someone looked),
   whether it is growing, flat or recovering, and whether it is continuous or bursty.
   A flat 2% and a 2% doubling every ten minutes are different incidents.

Add a sixth when relevant: **data integrity** — whether anything was lost, duplicated, or
written incorrectly. Any confirmed yes overrides the other five and raises severity on its
own, because the impact continues after the errors stop.

## How to measure, in any stack

Written as capabilities, not queries. Substitute whatever you run.

1. **Bound the window.** Find the first bad event and the last. Start narrow — the last
   hour — then widen until you find the clean period before impact. Note the boundary
   time; it is the single most useful clue for correlating against deploys and config
   changes.
2. **Get the denominator first.** Query the metrics store for total request volume on the
   affected path over the window. Without it, an error count has no meaning: 5,000 errors
   is catastrophic against 6,000 requests and noise against 6,000,000.
3. **Get the numerator, grouped.** Query the error aggregator for failures on that path,
   grouped by the dimensions above — region, tenant, endpoint, client version. The shape
   of the grouping is the finding: errors concentrated in one region point somewhere
   entirely different from errors spread evenly.
4. **Count distinct actors, not events.** Re-run the numerator as a distinct count of user
   or account identifiers. Compare to the event count; a large gap means retry
   amplification, and the honest population is the smaller number.
5. **Check the silent failures.** Not every impact raises an error. Look for the shapes
   that fail quietly: a success-rate metric that dropped without errors rising, latency
   past client timeout (the client gave up; your service logged success), queue depth
   growing, a scheduled job that did not run at all. Absence of errors is not evidence of
   absence of impact.
6. **State the uncertainty.** If a population cannot be measured — no telemetry on that
   path, logs sampled, one component's logs unreachable — say so explicitly and give a
   bound: *"at least 1,200 users; the mobile path is not instrumented, so the true number
   is higher."* An unmeasured dimension is an unknown, never a zero.

## Reporting format

Put this in the incident record at declaration and update it as the numbers move.

```
Blast radius — as of <time UTC>
  Window:     <impact start> → <ongoing | end>
  Users:      <distinct count> (<share> of active users in window)
  Requests:   <failed> / <total> on <path> (<rate>)
  Tenants:    <which cohorts, named or characterized>
  Scope:      <regions / zones / shards>
  Trend:      <growing | flat | recovering>, <basis for that call>
  Integrity:  <none observed | describe loss or corruption>
  Unmeasured: <paths or dimensions with no telemetry>
  → Severity: <Sev N>, because <the dimension that drives it>
```

The final line is the point of the exercise: it names which single dimension set the
severity, so that anyone can challenge the call by challenging that number rather than by
arguing about impressions.

## Common mistakes

- **Counting log lines as users.** One looping client can dominate every count. Always
  deduplicate by identity.
- **Measuring after mitigation and reporting that number.** The blast radius is the peak
  and the total over the window, not the residue now.
- **Letting "we don't have data" become "no impact."** These are opposite claims.
- **Reporting a rate with no denominator, or a denominator with no window.** Both are
  unfalsifiable.
- **Freezing the number at declaration.** Re-measure at every checkpoint; severity follows
  the number, both up and down.

## Handoffs

- Feed the severity line straight into the `incident-declaration` skill's severity table.
- Use the same dimensions to rank clusters in the `production-triage` skill — there, blast
  radius is what separates a cluster that deserves a ticket from noise above a count
  threshold.
