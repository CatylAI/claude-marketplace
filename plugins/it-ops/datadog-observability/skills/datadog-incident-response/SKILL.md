---
name: datadog-incident-response
description: "Confirm production impact and measure blast radius on Datadog, correlate against what shipped, then declare and maintain the incident record. Use when a service looks broken in Datadog, when severity needs a real number behind it, when someone asks 'how many users does this affect?', or when you need to know what changed in the last 24 hours. The Datadog execution of observability-core's incident-declaration and blast-radius skills."
license: MIT
---

# Datadog Incident Response

This skill executes `observability-core`'s `incident-declaration` and
`blast-radius` against a Datadog organization. Read those first for the
judgement: when to declare, how severity is read off impact, which dimensions
have to be measured. This skill supplies the calls.

Before anything else, confirm the credential and the site — an expired key and a
healthy system produce identical empty output:

```bash
curl -sS -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  "https://api.<SITE>/api/v1/validate"
```

Set these once for the session:

```bash
DD="https://api.<SITE>"
DDH=(-H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY")
```

## Step 0 — Do not declare a second incident for one event

```bash
curl -sS "${DDH[@]}" "$DD/api/v2/incidents?page[size]=20"
```

If one already covers this event, amend it rather than declaring again. Two
incidents for one outage split the timeline, and neither one is then the record.

## Step 1 — Confirm impact in three queries, in this order

Run these three before forming a hypothesis. Each rules something in or out, and
the order matters: the cheapest, denominator-bearing signal first.

### Query 1 — is the request path failing, and at what rate?

Metrics, not logs. This is the question no log query answers honestly, because
logs give you numerators very easily and denominators not at all.

```bash
NOW=$(date -u +%s)
THEN=$((NOW - 3600))

curl -sS -G "${DDH[@]}" "$DD/api/v1/query" \
  --data-urlencode "from=$THEN" --data-urlencode "to=$NOW" \
  --data-urlencode 'query=sum:trace.http.request.hits{service:<SERVICE>,env:<ENV>}.as_count()'
```

Then the same window, split by outcome:

```bash
curl -sS -G "${DDH[@]}" "$DD/api/v1/query" \
  --data-urlencode "from=$THEN" --data-urlencode "to=$NOW" \
  --data-urlencode 'query=sum:trace.http.request.errors{service:<SERVICE>,env:<ENV>}.as_count()'
```

The two together are the ratio. An error series with no hits series alongside it
means the path is down, not degraded — and it also means you should check
whether traffic stopped arriving, which is a different incident.

**Flagged, and it is the most common reason this query returns nothing.** The
`trace.*` metric family is named after the **span operation name**, not after a
fixed schema: `trace.http.request.*` is one shape among several, and a service
instrumented through a different integration reports under a different prefix
entirely. Do not assume the metric exists — list what this service actually
emits before querying it:

```bash
curl -sS -G "${DDH[@]}" "$DD/api/v1/search" --data-urlencode 'q=metrics:trace.'
```

**Flagged:** the exact shape of the metric-search endpoint and of the v2 metrics
listing has moved more than once. If that call does not behave, the APM service
page for the service lists its own metrics, and that is authoritative.

`.as_count()` is load-bearing here and is covered in
`datadog-monitors-and-queries` — without it you are reading a per-second rate
where you meant a count, and the number will be wrong by the width of the rollup
bucket.

**Rules in:** a real, measurable failure rate with a denominator.
**Rules out:** an alarming log line representing a handful of requests out of
millions.

### Query 2 — is anything *new* burning?

Aggregate, never enumerate. Group error logs by their error type and count them:

```bash
curl -sS "${DDH[@]}" -X POST -H "Content-Type: application/json" \
  "$DD/api/v2/logs/analytics/aggregate" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> status:error", "from": "now-1h", "to": "now" },
  "compute": [ { "aggregation": "count", "type": "total" } ],
  "group_by": [
    { "facet": "@error.kind", "limit": 20,
      "sort": { "aggregation": "count", "order": "desc" } }
  ]
}
JSON
```

Substitute whatever facet actually clusters your errors — `@error.kind`,
`@error.type`, `@event_type`, `resource_name`. **Flagged:** facet names are
per-organization, derived from what your services emit and from the log
pipelines that process them. Discover them from a raw sample before grouping on
one; grouping on a facet nothing populates returns one bucket with everything in
it, and looks like a finding.

**Error Tracking is the better tool for this question where you have it**, since
it clusters stack traces into durable issues with a first-seen, a last-seen and
an affected-user count already computed — which is precisely the novelty and
blast-radius information Step 2 and `dd-prod-triage` need. **Flagged:** the REST
surface for reading Error Tracking issues is newer than the rest of the API and
this document is not confident of its current path or request shape. Read the
issue list in the product, or verify the endpoint against the current API
reference before scripting against it. The log aggregation above is the fallback
that works everywhere, and it is what `dd-prod-triage` is written against.

Look at **first-seen before count**. A cluster first seen inside the suspected
impact window is the finding; a cluster with four million events and a first-seen
from last quarter is background.

**Rules in:** a specific fault signature.
**Rules out:** "the errors are new" when they have in fact been steady for months.

### Query 3 — what do the failing requests actually say?

Only now open the raw events, and only bounded:

```bash
curl -sS "${DDH[@]}" -X POST -H "Content-Type: application/json" \
  "$DD/api/v2/logs/events/search" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> status:error", "from": "now-1h", "to": "now" },
  "sort": "-timestamp",
  "page": { "limit": 20 }
}
JSON
```

Twenty records, not two thousand. `production-triage` is explicit: at most three
to five raw samples per cluster, and the tightest window that answers the
question.

**Rules in:** the concrete failure mode — which dependency, which status, which
tenant.
**Rules out:** a guess about the cause that the payload contradicts.

If Query 1 shows no rate change and Query 2 shows nothing new, you very likely do
not have a live incident — you have a triage item. Hand it to `dd-prod-triage`.

### The environment-tag trap, before you read any of it as clean

`production-triage` says to confirm the environment tag's exact literal before
querying, because a near-miss returns zero rows and looks identical to a clean
system. In Datadog that trap has a specific, nasty shape worth naming:

**A reserved tag and a same-named custom attribute are different things, and a
query can be valid on one telemetry surface and dead on the other.** Datadog
reserves `env`, `service`, `version`, `host`, `status` and `source`, and they are
populated by whatever ingestion path the telemetry took. A service that writes
`env` inside a JSON log payload gets it indexed as the **custom attribute**
`@env`, while the reserved `env` tag on those same log lines may be unset. A bare
`env:` term is then a term that can never be true, and because it is ANDed with
everything else it drags the whole query — including the query inside a monitor —
to zero.

Meanwhile the *same* filter string can be correct on spans, where the tracer
resolves `env` into a primary tag.

So: **prove the scope returns data before you read a narrow result as a clean
system.** Drop terms one at a time until something comes back, and note which
term was the dead one.

```bash
# Does the service produce logs at all in this window?
curl -sS "${DDH[@]}" -X POST -H "Content-Type: application/json" \
  "$DD/api/v2/logs/analytics/aggregate" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE>", "from": "now-1h", "to": "now" },
  "compute": [ { "aggregation": "count", "type": "total" } ]
}
JSON
```

Zero rows from a query you could not run correctly is not zero errors.

## Step 2 — Blast radius

`blast-radius` requires five dimensions measured with numbers and units *before*
severity is chosen. Here is where each comes from on Datadog.

### Requests, and the denominator

The `trace.*` hits and errors series from Query 1, over the same window, with
`.as_count()` on both. The ungrouped total is what turns "5,000 errors" into
"5,000 of 41,000 requests, 12%".

**Never report an error count without the total from the same window.** The
core's rule — a rate with no denominator is unfalsifiable — is the single most
common failure here.

Where a load balancer, CDN or gateway integration reports its own request
metrics, query those too and compare. **If the edge sees failures the service
does not, the fault is in front of the service**, and that narrows the search
enormously. It also tells you the service-side metrics are not a complete
denominator, which matters for the number you are about to put in the record.

### Scope — regions, clusters, zones, shards

Re-run the same query grouped, rather than summed:

```
sum:trace.http.request.errors{service:<SERVICE>,env:<ENV>} by {region}.as_count()
```

Substitute the tag your infrastructure actually carries — `region`,
`availability_zone`, `kube_cluster_name`, `kube_namespace`, `pod_name`,
`host`, or a shard tag of your own. **Flagged as per-organization:** which of
these exist depends entirely on your integrations and your agent configuration.
Read a sample event's tags rather than assuming; see
`datadog-monitors-and-queries` for the grouping syntax and its cardinality
limits.

One region failing while the others are clean is a different incident from all
regions failing — different cause, usually different severity, and it changes
whether shifting traffic is a viable mitigation.

### Affected users — and the zero that is not a zero

Distinct identities, not event counts. `blast-radius`: *ten thousand errors from
one retry-looping client is a different incident from ten thousand errors across
ten thousand people.*

```bash
curl -sS "${DDH[@]}" -X POST -H "Content-Type: application/json" \
  "$DD/api/v2/logs/analytics/aggregate" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> status:error", "from": "now-2h", "to": "now" },
  "compute": [ { "aggregation": "cardinality", "metric": "@usr.id" } ]
}
JSON
```

Substitute whatever identity attribute your services actually emit. **Flagged:**
`cardinality` as an aggregation and `@usr.id` as the attribute are both
conventions rather than guarantees — verify the aggregation is accepted and that
the attribute is populated before quoting a number from it.

**A zero here means *not measured* until you have confirmed the attribute is
populated.** Error Tracking's affected-user count has the same property: it
counts distinct users only for errors reported with a user identifier attached,
so a service that does not attach one reports zero for every issue, forever, and
that zero is worthless for ranking. Check, then say which it is.

Compare the distinct count to the event count. A large gap means retry
amplification, and the honest population is the smaller number.

### Tenants and segments

Datadog has no tenancy model of its own. Tenant attribution comes from whatever
tag or attribute your services emit. **If they emit none, that dimension is
unmeasurable in this environment** — record it as unknown and name the gap. Do
not substitute region for tenant and hope.

### Time — the impact-start boundary

The most valuable single number in the whole exercise, because it is what Step 3
correlates against.

Get it from the metric series rather than from logs: query the error series over
a window wide enough to contain the clean period before impact, and read the
first non-zero bucket.

```bash
NOW=$(date -u +%s)
THEN=$((NOW - 21600))   # six hours

curl -sS -G "${DDH[@]}" "$DD/api/v1/query" \
  --data-urlencode "from=$THEN" --data-urlencode "to=$NOW" \
  --data-urlencode 'query=sum:trace.http.request.errors{service:<SERVICE>,env:<ENV>}.as_count().rollup(sum, 300)'
```

The explicit `.rollup(sum, 300)` is the point: without it the bucket width is
chosen for you from the window length, so widening the window silently coarsens
your resolution and the boundary you read moves. Pin it, and widen the window
without changing it.

**Walk it deliberately.** Set the window a few hours before the suspected onset,
read the boundary, then move the start earlier and re-read. When the boundary
stops moving earlier, that is the real one. **If it keeps moving with every
widening, you do not yet have a boundary** — say so, and do not report the last
value as one. You have found the edge of your own window.

Then check the trend: growing, flat, or recovering, and on what basis. A flat 2%
and a 2% doubling every ten minutes are different incidents.

### Silent failures

Errors are not the only shape of impact, and several Datadog-visible failure
modes produce no error event at all:

- **Client-side timeouts.** The caller gave up; your service logged a success or
  logged nothing. Look at latency percentiles, not error counts — a p99 past the
  client's timeout is impact that never appears as an error.
- **Traffic that stopped arriving.** A request-count series that fell to zero is
  an outage that produces *fewer* errors, not more. An error-rate monitor is
  blind to it by construction.
- **Queue and stream backlog.** A consumer lag or queue-depth metric growing is
  impact that raises no error anywhere until the backlog is unrecoverable.
- **A scheduled job that did not run.** An absent run leaves no event. Absence is
  invisible to any `status:error` filter.
- **Restarts and evictions.** A container that stops and restarts may log nothing
  on the way out. The restart-count metric is where that lives.

The core's rule stands: **absence of errors is not evidence of absence of
impact.**

## Step 3 — What changed

`incident-declaration`'s scope-reset checkpoint asks explicitly what layers
outside the hypothesis are unchecked, and names configuration and infrastructure
changes in *adjacent* repositories in the last 24 hours as one of them. This is
the step that answers it.

### Deployment tracking — the correlation you actually want

Where services are tagged with `version`, Datadog correlates a version change
against that service's own metrics and will show you error rate and latency
before and after. That is strictly better than an event stream, because it is
already joined to the signal you care about.

Ask for the same metric split by version:

```
sum:trace.http.request.errors{service:<SERVICE>,env:<ENV>} by {version}.as_count()
```

**If every error carries one version and the previous version has none, you have
your cause** — and you have it without correlating two timelines by eye. If
`version` is not tagged on this service, that is a real gap: say so, and name it
as a follow-up, because it is cheap to fix and it is the single highest-value tag
during an incident.

### The event stream — everything that emitted an event

```bash
curl -sS -G "${DDH[@]}" "$DD/api/v2/events" \
  --data-urlencode 'filter[query]=tags:service:<SERVICE>' \
  --data-urlencode 'filter[from]=now-24h' \
  --data-urlencode 'filter[to]=now' \
  --data-urlencode 'page[limit]=50'
```

**Flagged:** the v2 events API and the older v1 event stream
(`GET /api/v1/events?start=<epoch>&end=<epoch>&tags=<tags>`) both exist and their
filter parameters differ. Verify which your organization answers on before
scripting against it; the parameter names are exactly the kind of thing that
returns an empty list rather than an error when wrong.

What lands in the event stream depends entirely on what your integrations post —
CI pipelines, configuration management, cloud-provider change events, alerting
transitions, and anything anyone submitted through the events API. It is a
partial change log, not a complete one.

### The changes that appear nowhere — name them as unchecked

This is the layer that gets missed, and the core's checkpoint exists because it
gets missed:

- **A console change in a cloud provider** is an audit-log entry in that
  provider, not a Datadog event, unless an integration forwards it.
- **A feature flag flipped in a SaaS product** leaves no trace in your telemetry
  at all.
- **A third party's own deploy** — an upstream API, a payment processor, a DNS or
  CDN provider — changes your system's behaviour and appears in none of your
  change logs.
- **A dashboard, monitor or pipeline edited in Datadog itself** changes what you
  are *looking at*, which during an incident is indistinguishable from a change
  in the system.

**Enumerate these as unchecked rather than concluding nothing changed.** "No
change found in the event stream within 30 minutes of the boundary" is a finding
and a useful one; "nothing changed" is a claim the event stream cannot support.

## Step 4 — Declare, in the product that actually has one

Unlike a cloud-native stack, Datadog has an incident record with severity, state,
detection method and time, services, responders, timeline and follow-ups. The
core's first non-negotiable — **declare at confirmation, not at diagnosis** —
therefore has no excuse here: the record lives in the same system as the
evidence.

Declare with the symptom, then amend as evidence arrives.

### Build the payload in a file, not inline

Narrative fields contain quotes, backticks, `$` and newlines. Hand-quoting them
into a `curl --data '...'` literal fails in ways that look like API errors:

```bash
PAYLOAD=$(mktemp)
python3 - "$PAYLOAD" <<'PY'
import json, sys

summary = (
    "Checkout requests failing with upstream connection resets. "
    "First bad event 14:02 UTC; 12% of requests on the checkout path. "
    "Cause not yet known."
)

payload = {"data": {"type": "incidents", "attributes": {
    "title": "[PROD] checkout — 12% request failures, cause unknown",
    "customer_impacted": True,
    "fields": {
        "severity":         {"type": "dropdown",    "value": "SEV-2"},
        "detection_method": {"type": "dropdown",    "value": "monitor"},
        "summary":          {"type": "textbox",     "value": summary},
        "services":         {"type": "multiselect", "value": ["<SERVICE>"]},
    },
}}}
json.dump(payload, open(sys.argv[1], "w"))
PY

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PAYLOAD" \
  || { echo "STOP: payload not built — not sending"; exit 1; }
```

**That validation step is not optional.** A generator that raised part way
through leaves a truncated or empty file, and `--data @file` sends it — producing
a `400` that reads like an API problem rather than a build problem. Same shape as
a credential variable that silently resolved to an empty string and sent an
unauthenticated request.

```bash
curl -sS -w '\nHTTP %{http_code}\n' "${DDH[@]}" \
  -X POST -H "Content-Type: application/json" \
  "$DD/api/v2/incidents" --data @"$PAYLOAD"
rm -f "$PAYLOAD"
```

Shape notes that are easy to get wrong:

- **Narrative fields go under `attributes.fields`**, each as
  `{"type": ..., "value": ...}` — not as bare `attributes.<name>`. The types are
  `dropdown`, `textbox` and `multiselect`.
- **`title` and `customer_impacted` are plain `attributes`**, not `fields`.
- **The response carries two identifiers and they are not interchangeable.**
  `data.id` is the UUID that `PATCH` takes in its URL *and* in its body; there is
  also a small public-facing id that appears in the web URL. Keep both.
- **Parse the response leniently.** Incident responses can carry raw control
  characters inside string fields, which makes a strict JSON parser fail on a
  body that is otherwise fine. **A parse failure is not a failed write** — read
  the HTTP status before concluding anything. A `201` with a traceback means the
  incident exists and only your parsing broke; re-read it rather than posting
  again, or you will file a duplicate.
- **`detection_method` is a finding, not a formality.** If a person reported it
  rather than a monitor, that means monitoring missed it. Say so in the summary
  and carry it into the follow-ups.

### Fix the detection time immediately

The detected timestamp defaults to the moment you called the API, which is almost
never when the incident was detected. Left alone it silently corrupts
time-to-detect for every report that reads this incident afterwards.

```bash
curl -sS "${DDH[@]}" -X PATCH -H "Content-Type: application/json" \
  "$DD/api/v2/incidents/<INCIDENT_UUID>" \
  --data '{"data":{"id":"<INCIDENT_UUID>","type":"incidents","attributes":{"detected":"<ISO8601>"}}}'
```

**`PATCH` requires `data.id` in the body as well as in the URL; omitting it
fails.** Set detected to when a human or a monitor first *knew* — not when impact
began. Impact onset belongs in the timeline, and the gap between the two is the
detection gap, which is one of the most useful things the record will ever carry.

### Sub-resources

Follow-up todos, responders, impacts and attachments hang off the incident.
**Flagged:** the URL shapes for these are not uniform — some sit under a
`relationships/` segment and some directly under the incident — and a wrong guess
returns a `404` that reads as "this feature is unavailable" rather than "wrong
path". Check the current API reference for each one rather than pattern-matching
from another. A `404` here is a path problem until proven otherwise.

Paste the `blast-radius` evidence block into the incident's summary, filled in:

```
Blast radius — as of <time UTC>
  Window:     <impact start from Step 2> → <ongoing | end>
  Users:      <distinct count> (source: log cardinality on <attribute> | Error Tracking | NOT MEASURED)
  Requests:   <failed> / <total> on <SERVICE> (<rate>)   [<the exact metric query>]
  Tenants:    <cohort, or NOT MEASURED — no tenant tag emitted>
  Scope:      <from the grouped query>
  Trend:      <growing | flat | recovering>, from the pinned rollup
  Integrity:  <none observed | describe>
  Unmeasured: <dimensions with no telemetry in this org>
  Changes:    <version split, events within 30 min of the boundary, or "none found">
  Unchecked:  <layers with no change log — flag providers, third parties, console edits>
  → Severity: <Sev N>, because <the dimension that drives it>
```

Every `NOT MEASURED` and every `Unchecked` line is doing real work. Leave them in.

## Step 5 — Maintain the record, then resolve

`incident-declaration`'s closing-out section lists what must be in the record
before it closes. The Datadog-specific additions:

| Field | Filled means |
|---|---|
| `title` | Service, symptom and — once known — the cause in a clause. Not "investigating errors". |
| `severity` | Deliberate, and re-evaluated when the blast-radius number moved. |
| `detection_method` | Accurate, including when it is an admission that monitoring missed it. |
| detected time | Corrected per Step 4, not the API call time. |
| root cause | The mechanism: the resource, the change, why it broke. Plus the hypotheses you **disproved**, with the evidence — a future reader with the same symptom will form the same wrong theory. |
| summary | Impact, blast radius, timeline, the detection gap, the mitigation. |
| services | Every affected service, plus the upstream that caused it. |
| `customer_impacted` | Answered, not defaulted. |
| responders | Everyone who actually responded, including reviewers of the fix. |
| attachments | The change that fixed it, the tracked item, the dashboard or monitor that showed it. |
| follow-ups | Every gap the incident exposed, each carrying its tracker key — see below. |

**Every follow-up becomes an owned item in the work tracker.** The core is
explicit that a checkbox living only in the incident record evaporates when the
incident closes. Datadog's todos are the right place to *link* it from; they are
not a backlog. Create the item in your tracker adapter, put its key in the todo
text, and link it back. Two qualifications the core adds and this skill repeats:
link an existing item rather than duplicating it, and if that existing item
belongs to someone else, do not reassign it to yourself to satisfy the rule.

**Resolve when impact is gone, not when the fix merges.** A merged change that
has not deployed has not resolved anything. Set the resolved timestamp to the
impact end you can evidence, not to the moment you called the API.

**Verify at the symptom, and prefer positive evidence over absence.** "The errors
stopped" only proves nobody hit the path. A successful request through the whole
chain, or a *different and later-stage* failure, is far stronger: a validation
error from the application proves the request cleared everything in front of it,
because a blocked request cannot produce one.

An incident with an empty root cause field reads, a quarter later, exactly like
no incident at all. **State any field you could not fill, and why.**

## Handoffs

- Severity, roles, comms cadence and the scope-reset checkpoint:
  `incident-declaration` in `observability-core`.
- The dimensions themselves and what makes a measurement honest: `blast-radius`,
  same plugin.
- Query syntax, monitor types, rollup and aggregation semantics:
  `datadog-monitors-and-queries` in this plugin.
- Sweeping the error backlog after the incident closes: `dd-prod-triage`.
- Answering one bounded question without spending this session's context on query
  output: the `dd-investigator` subagent.
- The blameless write-up: `incident-postmortem` in the `ops-workflows` plugin.
  Not here.
