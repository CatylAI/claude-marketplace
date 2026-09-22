---
name: gcp-incident-response
description: "Confirm production impact and measure blast radius on Google Cloud, then correlate against what shipped. Use when a GCP service looks broken, when severity needs a real number behind it, when someone asks 'how many users does this affect?', or when you need to know what changed in the last 24 hours across Cloud Build, Cloud Deploy and Cloud Audit Logs. The GCP execution of observability-core's incident-declaration and blast-radius skills."
license: MIT
---

# GCP Incident Response

This skill executes `observability-core`'s `incident-declaration` and `blast-radius` on a
Google Cloud project. Read those first for the judgement: when to declare, how severity is
read off impact, which dimensions have to be measured. This skill supplies the commands.

Before anything else, confirm the credential and the project — an expired token and a
healthy system produce identical empty output.

```
gcloud auth list
gcloud config get-value project
```

## Step 1 — Confirm impact in three queries, in this order

Run these three before forming a hypothesis. Each one rules something in or out, and the
order matters: the cheapest, broadest signal first.

### Query 1: is the request path actually failing, and at what rate?

Cloud Monitoring, not Logging. This is the denominator-bearing question and no log query
answers it honestly.

```
ACCESS_TOKEN=$(gcloud auth print-access-token)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
THEN=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)   # GNU date: date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ

curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/<PROJECT_ID>/timeSeries?\
filter=metric.type%3D%22run.googleapis.com%2Frequest_count%22%20AND%20\
resource.labels.service_name%3D%22<SERVICE>%22\
&interval.startTime=${THEN}&interval.endTime=${NOW}\
&aggregation.alignmentPeriod=60s\
&aggregation.perSeriesAligner=ALIGN_RATE\
&aggregation.crossSeriesReducer=REDUCE_SUM\
&aggregation.groupByFields=metric.label.%22response_code_class%22"
```

Grouping by `response_code_class` returns `2xx`, `4xx` and `5xx` as separate series, which
is the ratio you need. A 5xx series with no 2xx series alongside it means the path is
down, not degraded.

**Rules in:** a real, measurable failure rate with a denominator.
**Rules out:** an alarming log line that represents a handful of requests out of millions.

### Query 2: is anything new burning in Error Reporting?

The aggregate endpoint, never the raw event list. See `gcp-prod-triage` for why.

```
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://clouderrorreporting.googleapis.com/v1beta1/projects/<PROJECT_ID>/groupStats?\
timeRange.period=PERIOD_1_HOUR&order=COUNT_DESC&pageSize=10"
```

Look at `firstSeenTime` on the top groups before you look at `count`. A group whose
`firstSeenTime` falls inside the suspected impact window is the finding; a group with four
million events and a `firstSeenTime` from last quarter is background.

**Rules in:** a specific fault signature, with an affected-user count attached.
**Rules out:** "the errors are new" when they have in fact been steady for months.

### Query 3: what do the failing requests actually say?

Only now open the logs, and only bounded.

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND severity>=ERROR' \
  --project=<PROJECT_ID> --freshness=1h --limit=20 --order=desc --format=json
```

**Rules in:** the concrete failure mode — which dependency, which status, which tenant.
**Rules out:** a guess about the cause that the payload contradicts.

If Query 1 shows no rate change and Query 2 shows no new group, you very likely do not
have a live incident — you have a triage item. Hand it to `gcp-prod-triage`.

## Step 2 — Blast radius

`blast-radius` requires five dimensions measured with numbers and units *before* severity
is chosen. Here is where each comes from on GCP.

### Requests, and the denominator

The same `run.googleapis.com/request_count` time series as Query 1, aligned with
`ALIGN_RATE` or `ALIGN_DELTA`, reduced with `REDUCE_SUM`. Ask for it twice: once grouped
by `metric.label."response_code_class"` and once ungrouped. The ungrouped total is the
denominator that turns "5,000 errors" into "5,000 of 41,000 requests, 12%".

**Never report an error count without the total from the same window.** The core's rule —
a rate with no denominator is unfalsifiable — is the single most common failure here,
because Logging hands you numerators very easily and denominators not at all.

For traffic behind an external HTTP(S) load balancer, the equivalent metric is
`loadbalancing.googleapis.com/https/request_count`, also labelled by
`response_code_class`. Compare the two: if the load balancer sees 5xx that the service
does not, the fault is in front of the service (backend health, TLS, the LB config), and
that narrows the search enormously.

### Regions and infrastructure scope

Re-run the same query grouped by location instead of status class:

```
&aggregation.groupByFields=resource.label.%22location%22
```

One region failing and the others clean is a different incident from all regions failing —
different cause, usually different severity, and it changes whether shifting traffic is a
viable mitigation. For GKE, group by `resource.label."cluster_name"` and then by
`resource.label."namespace_name"`.

### Affected users

Error Reporting's `groupStats` response carries `affectedUsersCount` per group. It counts
distinct users **only for errors reported with a user identifier attached**; for errors
reported without one it is zero, and a zero there means *not measured*, not *nobody*.
Check whether your services populate the user field before quoting the number, and say
which it is.

Where the field is not populated, fall back to a distinct count from logs over the window
— extract whatever identity field your services do emit (`jsonPayload.user_id`,
`jsonPayload.tenant`, `labels.account`) and count distinct values yourself:

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND severity>=ERROR' \
  --project=<PROJECT_ID> --freshness=2h --limit=1000 \
  --format='value(jsonPayload.tenant)' | sort -u | wc -l
```

That `--limit` is load-bearing and it is also a ceiling: if the count comes back equal to
the limit, you have measured the limit, not the population. Raise it, or move the
aggregation to a log sink (see `gcp-log-queries`), and say in the report which you did.

### Tenants and segments

GCP has no tenancy model of its own. Tenant attribution comes from whatever label or
payload field your services emit. If they emit none, that dimension is **unmeasurable in
this environment** — record it as unknown and name the gap. Do not substitute region for
tenant and hope.

### Time

The impact-start boundary is the most valuable single number in the whole exercise,
because it is what correlates against Step 3. Find it by walking the window backwards
until you hit a clean period:

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND severity>=ERROR
   AND timestamp>="<WINDOW_START>"' \
  --project=<PROJECT_ID> --limit=1 --order=asc \
  --format='value(timestamp)'
```

**The window must be an explicit `timestamp` clause here, not `--freshness`.** This query
is ascending, and `--freshness` is silently ignored under `--order=asc` — it does not
error, it just reads from the start of retention. That failure is especially nasty in this
particular query: an unbounded ascending read returns the oldest error *ever recorded*,
which looks exactly like a very early impact-start and would send you hunting a change
that shipped months ago. See `gcp-log-queries` for the full constraint.

`--order=asc --limit=1` returns the oldest matching entry inside the window you named.
That is the first bad event **only if the window is wide enough to contain the clean
period before it** — otherwise you have found the edge of your own window and nothing
more.

So walk it deliberately: set `<WINDOW_START>` a few hours before the suspected onset, run
it, then move `<WINDOW_START>` earlier and re-run. When the returned timestamp stops
moving earlier, that is the real boundary. If it keeps moving with every widening, you do
not yet have a boundary — say so, and do not report the last value as one.

Cross-check against Cloud Monitoring, which retains longer than a cheap log read scans.

### Silent failures

Errors are not the only shape of impact, and GCP has several failure modes that produce no
error log at all:

- **Cloud Run request timeouts.** The client gave up; the container may have logged
  nothing. Look at `run.googleapis.com/request_latencies` percentiles, not error counts.
- **Container restarts and OOM kills.** `resource.type="k8s_container"` logs may end
  abruptly with no exception. Check `kubernetes.io/container/restart_count`.
- **Cloud Scheduler jobs that did not fire.** An absent run leaves no log line. Absence is
  invisible to a `severity>=ERROR` filter by construction.
- **Pub/Sub backlog.** `pubsub.googleapis.com/subscription/num_undelivered_messages`
  growing is impact that never raises an error anywhere.

The core's rule stands: absence of errors is not evidence of absence of impact.

## Step 3 — What changed in the last 24 hours

Three sources, and you need all three. Checking only the first two is how the most common
real cause gets missed.

### Builds

```
gcloud builds list --project=<PROJECT_ID> --limit=20 \
  --format='table(id, status, createTime, finishTime, source.repoSource.branchName)'
```

Filter to the window with `--filter='createTime>"2026-09-21T00:00:00Z"'` when the list is
long. A failed build that never deployed is not a cause; a successful build finishing four
minutes before your impact boundary almost certainly is.

### Deploys

```
gcloud deploy releases list --delivery-pipeline=<PIPELINE> --region=<REGION> \
  --project=<PROJECT_ID> --limit=10

gcloud deploy rollouts list --delivery-pipeline=<PIPELINE> --release=<RELEASE> \
  --region=<REGION> --project=<PROJECT_ID>
```

For services deployed straight to Cloud Run without a delivery pipeline, the revision list
is the deploy log:

```
gcloud run revisions list --service=<SERVICE> --region=<REGION> --project=<PROJECT_ID> \
  --format='table(metadata.name, metadata.creationTimestamp, status.conditions[0].status)'
```

Compare `creationTimestamp` against the impact boundary from Step 2.

### Configuration changes — the one that gets missed

**A change made through the Cloud Console is an audit log entry, not a deploy.** It does
not appear in `gcloud builds list`, it does not appear in `gcloud deploy`, and it does not
appear in a revision list. An IAM binding removed, a firewall rule edited, a Cloud SQL
flag flipped, a service account key disabled, a load balancer backend drained, a quota
adjusted — every one of these is a change that breaks production and leaves no trace in
any deploy pipeline. In the core's scope-reset checkpoint this is the layer that sits
outside the hypothesis and never gets checked.

```
gcloud logging read \
  'logName="projects/<PROJECT_ID>/logs/cloudaudit.googleapis.com%2Factivity"
   AND protoPayload.methodName!~"^google.monitoring"
   AND severity>=NOTICE' \
  --project=<PROJECT_ID> --freshness=24h --limit=100 --order=desc \
  --format='table(timestamp, protoPayload.methodName, protoPayload.authenticationInfo.principalEmail, protoPayload.resourceName)'
```

Read that output for the three fields that matter: **who** (`principalEmail`), **what**
(`methodName`), **which resource** (`resourceName`). A human principal — a person's
account rather than a service account — appearing near the impact boundary is the
highest-signal row in this entire skill.

Narrow to a suspected service by adding a `protoPayload.serviceName` clause, for example
`protoPayload.serviceName="compute.googleapis.com"` or `"run.googleapis.com"`.

Two caveats to state out loud rather than silently absorb:

- **Admin Activity audit logs are always on; Data Access audit logs are not.** If Data
  Access logging was never enabled for the service, reads and many configuration
  *readbacks* simply are not recorded. A clean audit query against a service with Data
  Access logging off is not evidence of no change.
- **Changes made outside GCP do not appear here at all** — a DNS record at your registrar,
  a third-party API's own deploy, a feature flag in a SaaS product. Name them as unchecked
  rather than concluding nothing changed.

## Step 4 — Declare, in the place GCP does not provide

GCP has no incident record. Cloud Monitoring's *incidents* are alert-policy state
transitions: they open when a condition trips and close when it clears, and they carry no
severity you assigned, no roles, no timeline, no hypotheses and no narrative. Treating one
as the incident record loses everything `incident-declaration` asks you to keep.

So the declaration artifact lives outside this plugin, in your incident tool or a shared
document. What this skill can give it is the evidence block — paste this, filled in, as
the blast-radius entry:

```
Blast radius — as of <time UTC>
  Window:     <impact start from Step 2> → <ongoing | end>
  Users:      <distinct count> (source: Error Reporting affectedUsersCount | distinct log field | NOT MEASURED)
  Requests:   <failed> / <total> on <SERVICE> (<rate>)   [run.googleapis.com/request_count]
  Tenants:    <cohort, or NOT MEASURED — no tenant label emitted>
  Scope:      <regions from the location grouping>
  Trend:      <growing | flat | recovering>, from the aligned time series
  Integrity:  <none observed | describe>
  Unmeasured: <dimensions with no telemetry in this project>
  Changes:    <builds / rollouts / audit entries within 30 min of the boundary>
  → Severity: <Sev N>, because <the dimension that drives it>
```

Every `NOT MEASURED` in that block is doing real work. Leave them in.

## Handoffs

- Severity, roles, comms cadence and the scope-reset checkpoint: `incident-declaration` in
  `observability-core`.
- The dimensions themselves and what makes a measurement honest: `blast-radius`, same
  plugin.
- Filter syntax, tracing one request across services, log-based metrics, sinks:
  `gcp-log-queries` in this plugin.
- Sweeping the error backlog after the incident closes: `gcp-prod-triage`.
- The blameless write-up: `incident-postmortem` in the `ops-workflows` plugin. Not here.
