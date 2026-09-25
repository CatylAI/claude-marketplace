# REST fallback for Monitoring, Error Reporting and Trace

Use these only when no Google Cloud MCP server is connected (see [setup.md](setup.md)).
Verify against current docs before relying on a detail here; the version notes at the end say
what was checked.

- [Rules for every call](#rules-for-every-call)
- [Monitoring: time series by filter](#monitoring-time-series-by-filter)
- [Monitoring: PromQL](#monitoring-promql)
- [Error Reporting: group stats](#error-reporting-group-stats)
- [Error Reporting: events for one group](#error-reporting-events-for-one-group)
- [Error Reporting: changing a group's status](#error-reporting-changing-a-groups-status)
- [Trace: list traces](#trace-list-traces)
- [What gcloud can and cannot read](#what-gcloud-can-and-cannot-read)
- [Version notes](#version-notes)

## Rules for every call

- Run each block as one Bash command. Shell variables do not carry over between separate tool
  calls, so a token or timestamp set in one call is empty in the next.
- Pass the query string with `curl -G --data-urlencode` rather than encoding it by hand.
- Timestamps are RFC 3339 in UTC. On Linux (GNU `date`):
  `date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ`. On macOS or BSD:
  `date -u -v-1H +%Y-%m-%dT%H:%M:%SZ`. Either platform:
  `python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))'`.

## Monitoring: time series by filter

`projects.timeSeries.list` with a filter is the primary path. MQL (`timeSeries.query`) is
deprecated: Google ended support for it and removed it from new console charts and alerting
policies, and recommends PromQL.

```
TOKEN=$(gcloud auth print-access-token)
START=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)   # macOS/BSD: date -u -v-1H +%Y-%m-%dT%H:%M:%SZ
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sS -G -H "Authorization: Bearer ${TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/<PROJECT_ID>/timeSeries" \
  --data-urlencode 'filter=metric.type="run.googleapis.com/request_count" AND resource.labels.service_name="<SERVICE>"' \
  --data-urlencode "interval.startTime=${START}" \
  --data-urlencode "interval.endTime=${END}" \
  --data-urlencode 'aggregation.alignmentPeriod=60s' \
  --data-urlencode 'aggregation.perSeriesAligner=ALIGN_RATE' \
  --data-urlencode 'aggregation.crossSeriesReducer=REDUCE_SUM' \
  --data-urlencode 'aggregation.groupByFields=metric.label."response_code_class"'
```

Variations:

- Total for the denominator: drop the `groupByFields` line.
- Region split: `aggregation.groupByFields=resource.label."location"`.
- GKE: `resource.label."cluster_name"`, then `resource.label."namespace_name"`.
- Load balancer: `metric.type="loadbalancing.googleapis.com/https/request_count"`.
- Latency: `run.googleapis.com/request_latencies` with `ALIGN_PERCENTILE_99`.
- Restarts: `kubernetes.io/container/restart_count`. Backlog:
  `pubsub.googleapis.com/subscription/num_undelivered_messages`.

## Monitoring: PromQL

Cloud Monitoring metric names map to PromQL by replacing the first `/` with `:` and the other
`.` and `/` with `_`, so `run.googleapis.com/request_count` becomes
`run_googleapis_com:request_count`, with the resource type in the `monitored_resource` label.

```
curl -sS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://monitoring.googleapis.com/v1/projects/<PROJECT_ID>/location/global/prometheus/api/v1/query_range" \
  --data @- <<'EOF'
{"query": "sum by (response_code_class) (rate(run_googleapis_com:request_count{monitored_resource=\"cloud_run_revision\",service_name=\"<SERVICE>\"}[5m]))",
 "start": "<WINDOW_START>", "end": "<WINDOW_END>", "step": "60s"}
EOF
```

## Error Reporting: group stats

```
curl -sS -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://clouderrorreporting.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/-/groupStats" \
  --data-urlencode 'timeRange.period=PERIOD_1_DAY' \
  --data-urlencode 'order=COUNT_DESC' \
  --data-urlencode 'timedCountDuration=3600s' \
  --data-urlencode 'pageSize=30'
```

| Parameter | Values | Notes |
|---|---|---|
| path | `projects/<P>/locations/-` | `-` requests every region. A bare `projects/<P>` reads only `global`. A single region: `locations/<REGION>`. |
| `timeRange.period` | `PERIOD_1_HOUR`, `PERIOD_6_HOURS`, `PERIOD_1_DAY`, `PERIOD_1_WEEK`, `PERIOD_30_DAYS` | No arbitrary start and end. Pick the smallest period that covers the window. |
| `order` | `COUNT_DESC` (default), `LAST_SEEN_DESC`, `CREATED_DESC`, `AFFECTED_USERS_DESC` | `CREATED_DESC` is the novelty list. |
| `timedCountDuration` | e.g. `3600s` | Without it, no `timedCounts` are returned, so there is no trend. |
| `alignment` | default `ALIGNMENT_EQUAL_AT_END` | Leave it at the default. |
| `serviceFilter.service` | service name | Scope to one service. |
| `pageSize`, `pageToken` | default page size 20 | Page rather than raising the size without limit. |

Groups with `resolutionStatus: MUTED` are excluded from group stats by default, so a muted group
that starts failing again does not appear in a sweep.

## Error Reporting: events for one group

Only after ranking, and only when the group's `representative` event is ambiguous:

```
curl -sS -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://clouderrorreporting.googleapis.com/v1beta1/projects/<PROJECT_ID>/locations/<LOCATION>/events" \
  --data-urlencode 'groupId=<GROUP_ID>' \
  --data-urlencode 'timeRange.period=PERIOD_1_DAY' \
  --data-urlencode 'pageSize=5'
```

Take `<LOCATION>` from the group's resource name in the group-stats response; `global` is the
default when the path has no location.

## Error Reporting: changing a group's status

`projects.groups.update` (`PUT .../v1beta1/projects/<P>/groups/<GROUP_ID>`, or the
`locations/<LOCATION>/groups/` form) sets `resolutionStatus` to `OPEN`, `ACKNOWLEDGED`,
`RESOLVED` or `MUTED`. It is a write, so the skills in this plugin do not call it. See
`gcp-prod-triage` for when a status change is worth proposing.

## Trace: list traces

```
curl -sS -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://cloudtrace.googleapis.com/v1/projects/<PROJECT_ID>/traces" \
  --data-urlencode 'startTime=<WINDOW_START>' \
  --data-urlencode 'endTime=<WINDOW_END>' \
  --data-urlencode 'pageSize=20'
```

## What gcloud can and cannot read

- `gcloud beta error-reporting` has two commands: `events report` (writes one event) and
  `events delete`, which deletes every error event in the project. Neither reads. A gcloud
  command that seems to read Error Reporting is worth rechecking before it runs.
- `gcloud monitoring` manages dashboards, alert policies, channels, snoozes and uptime checks.
  It has no command that reads time series.
- `gcloud logging read --freshness` works only with descending order and a filter without a
  `timestamp` clause; otherwise it is ignored without a warning.

## Version notes

Checked on 2026-09-25 against: the Error Reporting v1beta1 protos in `googleapis/googleapis`
(`error_stats_service.proto`, `common.proto`, `error_group_service.proto`); Google's MQL
deprecation notice; the `@google-cloud/observability-mcp` 0.2.3 README. The gcloud statements
were checked against Google Cloud SDK 586.0.0 help text on 2026-09-22 and against the
`gcloud logging read` and `gcloud beta error-reporting events delete` reference pages. The PromQL request shape
and metric-name mapping come from Google's PromQL for Cloud Monitoring pages via search excerpts;
confirm them in Metrics Explorer before relying on a number.
