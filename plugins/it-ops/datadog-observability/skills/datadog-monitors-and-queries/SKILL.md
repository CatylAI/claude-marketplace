---
name: datadog-monitors-and-queries
description: "Datadog query cookbook — metric query syntax, log search syntax, the aggregation and rollup semantics that decide whether a number means what you think, and the monitor types worth knowing. Use when you need a working Datadog query right now, when a graph and an API call disagree, when a monitor fires on something that is not happening, or when a query returns a suspiciously round number."
license: MIT
when_to_use: "Mid-incident, when you need a query that works on the first try. Also when a result looks wrong and you cannot tell whether the system is fine or the query is."
---

# Datadog queries

Written for the moment you need a number and do not have time to discover the
query language. Every example uses placeholders: `<SITE>`, `<SERVICE>`, `<ENV>`,
`<MONITOR_ID>`.

## The metric query, and the three things that change its meaning

```
GET https://api.<SITE>/api/v1/query?from=<unix_s>&to=<unix_s>&query=<query>
```

A query string has four parts, and three of them silently change the answer:

```
sum:trace.http.request.hits{service:<SERVICE>,env:<ENV>} by {resource_name}.as_rate()
└┬┘ └──────────┬──────────┘ └──────────┬────────────┘   └───────┬───────┘ └───┬───┘
 │              │                       │                        │             │
 │              metric                  scope                     grouping      modifier
 space aggregation
```

- **Space aggregation** (`sum`, `avg`, `min`, `max`) folds the tagged series
  together. `avg:` over a fleet answers a different question from `sum:` over the
  same fleet, and for a count metric `avg:` is almost always the wrong one — it
  reports the average host's traffic, not the traffic.
- **Grouping** (`by {tag}`) decides how many series come back. Absent, everything
  collapses into one line and a single bad region disappears into the mean. This
  is the difference between "error rate is 2%" and "error rate is 2% overall and
  60% in one region", which are different incidents.
- **The rollup**, below, which is the one that actually catches people out.

### Rollup: the number changes with the width of the graph

Datadog buckets points to a time interval. If you do not choose the interval, one
is chosen for you from the width of the time window — so **the same query over one
hour and over one day returns different values**, and a dashboard that looked
right at 1h reads wrong at 1d. During an incident you will widen the window, and
that is exactly when the silent change bites.

Be explicit:

```
sum:trace.http.request.errors{service:<SERVICE>}.as_count().rollup(sum, 60)
```

- `.rollup(sum, 60)` — sum each 60-second bucket. Use for counts.
- `.rollup(avg, 60)` — average within the bucket. Use for gauges.
- `.as_count()` — report the raw count in each bucket.
- `.as_rate()` — report per-second. A count metric graphed without `.as_count()`
  may already be rate-normalised, which is why "requests" sometimes reads `12.7`.

**The rule: state the rollup on any number you are going to put in an incident
channel.** An unstated rollup is a number whose meaning depends on the width of
the window it was read in, and nobody reading it later can recover that.

### An error rate needs a denominator with the same shape

A count of errors is not a rate, and the most common blast-radius mistake is
reporting one as the other. Both sides need the same scope, the same grouping and
the same rollup:

```
(sum:trace.http.request.errors{service:<SERVICE>,env:<ENV>} by {region}.as_count().rollup(sum,60)
 / sum:trace.http.request.hits{service:<SERVICE>,env:<ENV>} by {region}.as_count().rollup(sum,60)) * 100
```

If the denominator is scoped differently from the numerator — a missing `env`, a
different grouping — the ratio is arithmetic on unrelated numbers and will look
plausible.

## Log search

```
POST https://api.<SITE>/api/v2/logs/events/search
{ "filter": { "query": "<query>", "from": "now-1h", "to": "now" },
  "page":   { "limit": 50 },
  "sort":   "-timestamp" }
```

| Construct | Example | Note |
|---|---|---|
| Facet equality | `service:<SERVICE>` | Facets are indexed; free text is not. Always lead with one. |
| Status | `status:error` | Mapped from the log's level at intake. |
| Free text | `"connection reset"` | Quoted for a phrase. Slower than a facet. |
| Attribute | `@http.status_code:>=500` | The `@` prefix is a log *attribute*, not a tag. This distinction is the single most common log-query error. |
| Wildcard | `@url:*/api/*` | Leading wildcards are expensive. |
| Boolean | `AND` `OR` `-` | `-status:info` excludes. Parenthesise anything non-trivial. |
| Existence | `@error.stack:*` | Has the attribute at all. |

**`@attribute` versus `tag:` is not a style choice.** Tags come from the host,
container and integration; attributes come from the log body. `host:web-1` and
`@host:web-1` can both exist and mean different things, and a query that uses the
wrong one returns zero rows and looks like a clean system.

### Aggregate before you read

```
POST https://api.<SITE>/api/v2/logs/analytics/aggregate
{ "filter":  { "query": "service:<SERVICE> status:error", "from": "now-4h", "to": "now" },
  "compute": [ { "aggregation": "count" } ],
  "group_by":[ { "facet": "@error.type", "limit": 20,
                 "sort": { "aggregation": "count", "order": "desc" } } ] }
```

Reading raw events first is the mistake `production-triage` exists to prevent.
Aggregate, rank, then read the top few. See `dd-prod-triage`.

## Error Tracking: the clustering is already done

Error Tracking groups stack traces into durable **issues** carrying first-seen,
last-seen, total count and affected-user count. That is the blast-radius shape
`observability-core` asks for, without you writing the clustering. Start there
rather than grouping logs by hand; drop to log search only for a service that
does not report into it.

## Monitors

| Type | Fires on | Watch for |
|---|---|---|
| Metric | A metric crossing a threshold over a window | The evaluation window and the rollup interact. A 5-minute window on a sparse metric evaluates almost nothing. |
| Anomaly | Deviation from a learned baseline | Needs weeks of history. On a new service it is noise. |
| Composite | A boolean over other monitors | The only clean way to say "errors up AND traffic normal". |
| Log | A log query crossing a count | Only sees indexed logs — see the exclusion trap below. |
| APM | Trace metrics: latency, error rate | Prefer over log monitors for a traced service. |
| Watchdog | Datadog's own detection | Useful signal, not a substitute for your own. |

Read one:

```
GET https://api.<SITE>/api/v1/monitor/<MONITOR_ID>
```

**`notify_no_data` is the setting that decides whether silence is an alert.** A
monitor without it cannot distinguish "healthy" from "the agent stopped
reporting" — the same degraded-versus-successful confusion this marketplace keeps
returning to. If a service can stop emitting, that is a condition worth alerting
on, and an unstated `no_data` window is a monitor that will be quiet during the
one failure it most needs to catch.

## Three traps worth knowing before you trust a number

- **Log exclusion filters.** An index can be configured to drop or sample a
  matching class of logs. Your query then returns a real number that is not the
  population. Check the index configuration before reporting a log-derived count
  as a total — and say in your report that you checked.
- **Metric retention and rollup at age.** Older data is stored at coarser
  resolution. A query over last month cannot resolve a two-minute spike; absence
  of a spike there is not evidence it did not happen.
- **Custom metric cardinality.** A metric tagged with something unbounded (a user
  id, a request id) may be dropped or truncated server-side. A query over it
  returns something; it is not the truth.

## Cost, and the incident hazard

Datadog bills ingestion, indexed log volume and custom metrics. Reads are not the
expensive part — but a broad unbounded log search during an incident is slow, and
several responders each running one turns a slow query into a queue behind the
one person everyone is waiting on. Bound the window, lead with a facet, set a
`limit`, then widen one dimension at a time.
