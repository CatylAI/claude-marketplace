---
name: gcp-log-queries
description: "Cloud Logging query cookbook — gcloud logging read anatomy, the Logging query language, and ready-to-paste filters for Cloud Run 5xx, uncaught exceptions, a single request traced across services, GKE pod logs and load balancer request logs. Use whenever you need a GCP log filter, are writing a log-based metric, are deciding between querying Logging and querying a sink, or a log query is running slow or returning nothing."
license: MIT
when_to_use: "Mid-incident, when you need a working filter immediately. Also when a query returns zero rows and you cannot tell whether the system is clean or the filter is wrong."
---

# Cloud Logging Query Cookbook

Dense reference for getting data out of Cloud Logging correctly and cheaply. Open it
mid-incident; it is written to be scanned, not read.

## `gcloud logging read` anatomy

```
gcloud logging read '<FILTER>' \
  --project=<PROJECT_ID> \
  --freshness=1h \
  --limit=50 \
  --order=desc \
  --format=json
```

| Flag | What it does | Guidance |
|------|--------------|----------|
| `'<FILTER>'` | Positional. A Logging query-language expression. Single-quote it so the shell leaves the inner double quotes alone. | Newlines inside the quoted string are fine and make long filters readable. |
| `--project` | Which project's log buckets are read. | Always pass it explicitly during an incident. Relying on the ambient `gcloud config` default is how you query the wrong project and report a clean result. |
| `--freshness` | Adds a `timestamp >=` restriction relative to now. Accepts `30m`, `6h`, `2d`. Default `1d`. | **Always set it — and read the constraint below, because it is silently ignored in two cases.** |
| `--limit` | Caps entries returned. | Always set it. A returned count equal to the limit means you measured the limit, not the population. |
| `--order` | `desc` (newest first, the default) or `asc` (oldest first). | `--order=asc` **disables `--freshness`** — bound the window with an explicit `timestamp` clause instead. See below. |
| `--format` | `json`, `yaml`, `table(...)`, `value(...)`. | `value(field)` piped to `sort -u | wc -l` is the cheapest distinct count you have from the CLI. |
| `--bucket` / `--view` / `--location` | Read a non-default log bucket or view. | Needed when logs are routed to a dedicated bucket rather than `_Default`. |

### The two cases where `--freshness` is silently ignored

Verified against Google Cloud SDK 586.0.0. `gcloud logging read --help` states it
outright: *"Works only with DESC ordering and filters without a timestamp."*

So `--freshness` does nothing — with no warning, no error, and a successful exit — when
either of these is true:

1. **`--order=asc` is set.** The query runs unbounded and reads from the beginning of
   retention. This is the dangerous one, because ascending order is exactly what you reach
   for when hunting the *first* occurrence of a fault, which is exactly when you are least
   inclined to doubt the result.
2. **The filter already contains a `timestamp` clause.** Here the filter governs, which is
   usually what you wanted — but if the two disagree, the flag is not the one that wins.

**The rule that follows:** bound the window *once*, and pick the mechanism by ordering.
Descending, rolling window → `--freshness`. Ascending, or any fixed historical window →
an explicit `timestamp` comparison in the filter, and no `--freshness` at all.

```
# WRONG — reads from the start of retention; --freshness is discarded
gcloud logging read '<FILTER>' --project=<PROJECT_ID> --freshness=1h --order=asc --limit=1

# RIGHT — the bound is in the filter, so ordering cannot discard it
gcloud logging read '<FILTER>
   AND timestamp>="2026-09-21T14:00:00Z"
   AND timestamp<"2026-09-21T15:00:00Z"' \
  --project=<PROJECT_ID> --order=asc --limit=1
```

### Why `--freshness` matters more than it looks

**An unbounded read scans a far wider window than you intended.** Without a time bound the
query walks a much larger span of the log bucket, which is slow, consumes read quota, and
during an incident stalls the one person everyone is waiting on. It also tends to return
*older* matching entries first under `desc` ordering on a busy project, which reads as
"the problem started hours ago" when it did not.

**The rule: every read is bounded.** Set `--freshness`, or put an explicit `timestamp`
comparison in the filter. Start at `1h`, widen deliberately. Never run a filter you have
not bounded, and never widen and remove the `--limit` in the same step — you will not know
which change produced the new result.

## The Logging query language

| Construct | Example | Notes |
|-----------|---------|-------|
| Resource type | `resource.type="cloud_run_revision"` | The single highest-leverage clause. Always include one; it is what restricts the scan. |
| Resource labels | `resource.labels.service_name="<SERVICE>"` | Label names differ per resource type. `resource.labels.cluster_name`, `.namespace_name`, `.pod_name`, `.container_name` for GKE. |
| Severity | `severity>=ERROR` | Ordered enum: `DEFAULT < DEBUG < INFO < NOTICE < WARNING < ERROR < CRITICAL < ALERT < EMERGENCY`. `>=WARNING` catches degradation that `>=ERROR` misses. |
| Timestamp | `timestamp>="2026-09-21T14:00:00Z" AND timestamp<"2026-09-21T15:00:00Z"` | RFC 3339, quoted. Use for a fixed historical window; use `--freshness` for a rolling one. |
| Log name | `logName="projects/<PROJECT_ID>/logs/run.googleapis.com%2Frequests"` | The log id is URL-encoded inside the filter — `/` becomes `%2F`. This trips everyone once. |
| Structured payload | `jsonPayload.error.code=503` | Any depth. Quote keys containing dots or dashes: `jsonPayload."error-code"`. |
| Unstructured payload | `textPayload:"connection reset"` | For services that log plain strings. |
| Labels | `labels.revision="<REVISION>"` | User labels, distinct from `resource.labels`. |
| HTTP request | `httpRequest.status>=500`, `httpRequest.requestUrl:"/api/"` | Present on request logs (Cloud Run, load balancers, App Engine). |
| Exact match | `jsonPayload.message="timeout"` | Whole-value equality. |
| Substring / has | `jsonPayload.message:"timeout"` | The `:` operator. Matches on tokenized substring, not a raw `strstr` — it splits on delimiters, so `:"time"` will not match `timeout`. |
| Regex | `jsonPayload.message=~"5\\d\\d"` | RE2 syntax. `!~` for not-matching. Regex is the slowest operator here; reach for `:` first. |
| Negation | `NOT severity=INFO`, `-resource.labels.service_name="<SERVICE>"` | `NOT` and the leading `-` are equivalent. |
| Boolean | `AND`, `OR`, parentheses | `AND` is implicit between adjacent clauses, but write it. An implicit operator next to a `NOT` is a readability trap. |
| Existence | `jsonPayload.tenant:*` | Entries where the field is present at all. Useful for finding which services emit an identity field. |

**Zero rows is ambiguous.** It means "no matching entries" or "your filter is wrong" and
the two look identical. Before concluding a system is clean, drop the narrowest clause and
confirm the query returns *something*. The core's rule applies verbatim: zero rows from a
query you could not run correctly is not zero errors.

## Ready-to-paste filters

### 5xx from one Cloud Run service

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=50 --order=desc \
  --format='table(timestamp, httpRequest.status, httpRequest.requestUrl, resource.labels.revision_name)'
```

Including `revision_name` in the output is what turns this into a deploy correlation: if
every 5xx carries one revision and the previous revision has none, you have your cause.

### Uncaught exceptions, by service

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND severity>=ERROR
   AND (jsonPayload.stack_trace:* OR textPayload:"Traceback" OR textPayload:"Exception")' \
  --project=<PROJECT_ID> --freshness=6h --limit=100 --order=desc \
  --format='value(resource.labels.service_name)' | sort | uniq -c | sort -rn
```

This is a poor substitute for Error Reporting's grouping — see `gcp-prod-triage` — but it
works for services that do not report into Error Reporting at all.

### One request, traced across every service it touched

Cloud Logging stamps entries with a `trace` field when tracing is propagated. The literal
form is `projects/<PROJECT_ID>/traces/<TRACE_ID>`; in structured payloads written by
client libraries the same value appears as `logging.googleapis.com/trace`.

Get the trace id from a failing request first:

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=1 \
  --format='value(trace)'
```

Then pull every entry sharing it, across all resource types, oldest first:

```
gcloud logging read \
  'trace="projects/<PROJECT_ID>/traces/<TRACE_ID>"
   AND timestamp>="<WINDOW_START>"' \
  --project=<PROJECT_ID> --limit=200 --order=asc \
  --format='table(timestamp, resource.labels.service_name, severity, jsonPayload.message, textPayload)'
```

The bound is an explicit `timestamp` clause, not `--freshness`, because this query is
ascending — see the ordering constraint above. `<WINDOW_START>` is an RFC 3339 instant
such as `2026-09-21T14:00:00Z`.

Deliberately no `resource.type` clause: the point is to cross service boundaries. This is
the single best query in this document for "which hop actually failed" — the last entry
before the error is usually the answer. Cloud Trace shows the same request as a latency
waterfall; use it when the question is *where the time went* rather than *what was logged*.

If the `trace` field is empty, trace context is not being propagated. That is a real gap:
say so rather than reconstructing a request path by eye from timestamps.

### GKE container logs for one pod

```
gcloud logging read \
  'resource.type="k8s_container"
   AND resource.labels.cluster_name="<CLUSTER>"
   AND resource.labels.namespace_name="<NAMESPACE>"
   AND resource.labels.pod_name="<POD>"
   AND timestamp>="<WINDOW_START>"' \
  --project=<PROJECT_ID> --limit=200 --order=asc \
  --format='table(timestamp, severity, resource.labels.container_name, textPayload, jsonPayload.message)'
```

For the pod's lifecycle rather than its stdout — scheduling, evictions, OOM kills — query
`resource.type="k8s_pod"` and `resource.type="k8s_node"` instead. A container that stops
logging with no error is usually explained there, not in `k8s_container`.

### Load balancer request logs by status class

```
gcloud logging read \
  'resource.type="http_load_balancer"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=100 --order=desc \
  --format='table(timestamp, httpRequest.status, httpRequest.requestUrl, jsonPayload.statusDetails, resource.labels.backend_service_name)'
```

`jsonPayload.statusDetails` is the field worth reading: values such as
`failed_to_connect_to_backend`, `backend_timeout` or `response_sent_by_backend` tell you
whether the load balancer ever reached your service. If it did not, no amount of
service-side log reading will explain the 5xx.

Load balancer request logging is **sampled and off by default** on some backend services.
Confirm it is enabled before reading an empty result as no traffic.

## When a filter should become a log-based metric

A filter you have run more than twice, or one you want to alert on or chart against other
series, should stop being a read and become a counter.

```
gcloud logging metrics create <METRIC_NAME> \
  --project=<PROJECT_ID> \
  --description="5xx responses from <SERVICE>" \
  --log-filter='resource.type="cloud_run_revision"
                AND resource.labels.service_name="<SERVICE>"
                AND httpRequest.status>=500'
```

The metric then appears in Cloud Monitoring as
`logging.googleapis.com/user/<METRIC_NAME>`, where it can be aggregated, alerted on, and
placed beside request volume to produce a rate instead of a count.

Three things to know:

- **Counting starts at creation.** A log-based metric has no history. Creating one
  mid-incident gives you nothing about what already happened, so create it as a follow-up,
  not as a diagnostic step.
- **Creating a metric is a mutation.** It is the one write this cookbook mentions, and it
  is out of scope for a read-only responder and for the `gcp-investigator` subagent.
- **Label cardinality is the trap.** Extracting a high-cardinality field (user id, request
  id) as a metric label produces an unusable and expensive metric. Label on bounded
  dimensions only: service, region, status class.

## Cost, quota and the incident hazard

- **Ingestion and retention are what you pay for.** Cloud Logging bills on log volume
  ingested and on storage held beyond the default retention. Reads are not billed per
  query in the same way — but they are **quota-limited**, and the entries-read API has a
  per-minute ceiling shared by everyone and everything querying the project.
- **The real incident hazard is time and quota, not the invoice.** A broad unbounded query
  can take minutes, and several responders each running one can exhaust the read quota and
  start throttling the alerting and export paths that other people are depending on. The
  person who runs `gcloud logging read` with no `--freshness` on a busy project during a
  Sev1 has made the incident worse.
- **Narrow before you widen, always.** `resource.type` plus a short `--freshness` plus a
  `--limit`, then relax one dimension at a time.
- **Exclusions and sinks change what is even there.** A project with an exclusion filter
  may never have ingested the entries you are looking for. `gcloud logging sinks list
  --project=<PROJECT_ID>` shows where data goes; check it before concluding a log does not
  exist.

## Sinks: when querying the sink beats querying Logging

Log sinks route entries out of Logging to another destination. Check what exists:

```
gcloud logging sinks list --project=<PROJECT_ID>
gcloud logging sinks describe <SINK_NAME> --project=<PROJECT_ID>
```

| Destination | Query it instead when |
|-------------|----------------------|
| **BigQuery** | You need aggregation, a join, a distinct count over a large window, or a window older than log retention. SQL does in one statement what a CLI read plus `sort -u` approximates badly. Note the inverse cost profile: BigQuery bills per byte scanned, so partition-prune on the date column or the query is expensive rather than merely slow. |
| **Cloud Storage** | You are doing forensics over weeks or months, or Logging retention has already expired the window. Slow to query, cheap to keep. |
| **Pub/Sub** | Never, for investigation — it is a live stream with no history. Relevant only as the answer to "what is already consuming these events". |

The heuristic: **Logging answers "what happened just now, on this service"; BigQuery
answers "how many, over how long, across what".** A distinct-user count over 24 hours is a
BigQuery question being asked badly at a CLI prompt. If a sink exists, use it and say in
your report that you did.

If no sink exists and the window you need has aged out of retention, that is an
unmeasurable dimension. Name it as unknown.
