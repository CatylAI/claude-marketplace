# Datadog REST fallback

Use these when the session has no Datadog MCP tools (see `setup.md`). Every block is
self-contained: it reads `DD_API_KEY`, `DD_APPLICATION_KEY` and `DD_SITE` from the environment
and stops with a message if one is missing, because a shell variable set in one Bash call is
gone in the next. Replace every `<…>` placeholder; never paste a monitor ID, incident ID,
service name or organization value from an example.

Contents

- [Credential check](#credential-check)
- [Metrics](#metrics): timeseries, list a service's metrics
- [Logs](#logs): search, aggregate, distinct count, index configuration
- [Error Tracking](#error-tracking): search, one issue, state and assignee
- [Events](#events)
- [Monitors](#monitors)
- [Incidents](#incidents): find open ones, create, amend, sub-resources
- [Verify against current docs](#verify-against-current-docs)

## Credential check

```bash
curl -sS -w '\nHTTP %{http_code}\n' \
  -H "DD-API-KEY: ${DD_API_KEY:?DD_API_KEY is not set}" \
  -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?DD_APPLICATION_KEY is not set}" \
  "https://api.${DD_SITE:?DD_SITE is not set, for example datadoghq.com}/api/v2/validate_keys"
```

`HTTP 200` with `{"status":"ok"}` means both keys are valid for this site. Anything else: stop
and report it. To tell which key is wrong, `GET /api/v1/validate` with only the API key header
checks the API key alone. If `validate_keys` returns `404`, use `GET /api/v2/current_user`
with both headers instead.

## Metrics

### Timeseries

```bash
NOW=$(date -u +%s)
curl -sS -G \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v1/query" \
  --data-urlencode "from=$((NOW - 3600))" --data-urlencode "to=$NOW" \
  --data-urlencode 'query=sum:trace.<OPERATION>.errors{service:<SERVICE>,env:<ENV>}.as_count().rollup(sum, 60)'
```

`from` and `to` are Unix seconds. Change the window by changing the `3600`; keep the rollup
fixed so the bucket width does not move with it.

### List a service's metrics

`trace.*` metric names follow the span operation name, so list what the service emits before
querying it:

```bash
curl -sS -G \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/metrics" \
  --data-urlencode 'filter[tags]=service:<SERVICE>' \
  --data-urlencode 'window[seconds]=86400' \
| python3 -c 'import json,sys; [print(m["id"]) for m in json.load(sys.stdin).get("data", []) if m["id"].startswith("trace.")]'
```

This replaces the deprecated `GET /api/v1/search?q=metrics:…`.

## Logs

### Search (bounded raw samples)

```bash
curl -sS -X POST -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/logs/events/search" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> env:<ENV> status:error", "from": "now-1h", "to": "now" },
  "sort": "-timestamp",
  "page": { "limit": 20 }
}
JSON
```

### Aggregate: count by facet, top N by count

```bash
curl -sS -X POST -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/logs/analytics/aggregate" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> env:<ENV> status:error", "from": "now-1h", "to": "now" },
  "compute": [ { "aggregation": "count", "type": "total" } ],
  "group_by": [
    { "facet": "<@error.kind>", "limit": 20,
      "sort": { "type": "measure", "aggregation": "count", "order": "desc" } }
  ]
}
JSON
```

`"type": "measure"` is required for a count sort. The sort type defaults to `alphabetical`,
so without it the "top 20" are the first 20 facet values alphabetically.

Drop `group_by` for a plain count, which is also the scope check: if
`service:<SERVICE>` alone returns zero in a window where the service was serving, the scope is
wrong, not the system healthy.

### Distinct users

```bash
curl -sS -X POST -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/logs/analytics/aggregate" --data @- <<'JSON'
{
  "filter": { "query": "service:<SERVICE> env:<ENV> status:error", "from": "now-2h", "to": "now" },
  "compute": [ { "aggregation": "cardinality", "metric": "<@usr.id>" } ]
}
JSON
```

Run it again with the filter `service:<SERVICE> env:<ENV> status:error <@usr.id>:*` and a
`count`: if that count is far below the error count, most errors carry no user ID and the
distinct count is a floor.

### Index configuration (exclusion filters and quotas)

```bash
curl -sS \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v1/logs/config/indexes" \
| python3 -c 'import json,sys; [print(i["name"], "filters:", [f.get("filter",{}).get("query") for f in i.get("exclusion_filters",[])], "daily_limit:", i.get("daily_limit")) for i in json.load(sys.stdin).get("indexes",[])]'
```

An exclusion filter matching your query, or a daily limit that was reached, means a log count
is not the population.

## Error Tracking

### Search issues

```bash
TO_MS=$(( $(date -u +%s) * 1000 )); FROM_MS=$(( TO_MS - 86400000 ))
curl -sS -X POST -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/error-tracking/issues/search?include=issue" --data @- <<JSON
{
  "data": {
    "type": "search_request",
    "attributes": {
      "query": "service:<SERVICE> env:<ENV>",
      "from": $FROM_MS,
      "to": $TO_MS,
      "track": "trace",
      "order_by": "TOTAL_COUNT"
    }
  }
}
JSON
```

- `data.type: "search_request"` is required; the request fails without it.
- `from` and `to` are Unix milliseconds. At most 100 issues come back per request.
- `track` is `trace`, `logs` or `rum`; alternatively set `persona` (`ALL`, `BROWSER`, `MOBILE`,
  `BACKEND`). One of the two is required.
- `order_by` is `TOTAL_COUNT`, `FIRST_SEEN`, `IMPACTED_SESSIONS` or `PRIORITY`.
- Each result carries `total_count`, `impacted_users` and `impacted_sessions` for the window.
  With `include=issue`, the included issue carries `error_type`, `error_message`,
  `service`, `first_seen`, `last_seen` (ms), `first_seen_version`, `last_seen_version` and
  `state`. Add `issue.case` to the include list to see a linked case or ticket.

### One issue

```bash
curl -sS \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/error-tracking/issues/<ISSUE_ID>"
```

### State and assignee (mutations: only with the user's explicit approval)

```bash
curl -sS -w '\nHTTP %{http_code}\n' -X PUT -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/error-tracking/issues/<ISSUE_ID>/state" \
  --data '{"data":{"id":"<ISSUE_ID>","type":"error_tracking_issue","attributes":{"state":"<STATE>"}}}'
```

`<STATE>` is one of `OPEN`, `ACKNOWLEDGED`, `RESOLVED`, `IGNORED`, `EXCLUDED`. The assignee
is set the same way with `PUT …/issues/<ISSUE_ID>/assignee`.

## Events

```bash
curl -sS -G \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/events" \
  --data-urlencode 'filter[query]=service:<SERVICE>' \
  --data-urlencode 'filter[from]=now-24h' \
  --data-urlencode 'filter[to]=now' \
  --data-urlencode 'page[limit]=50'
```

The older `GET /api/v1/events` takes different parameters (`start`, `end`, `tags`). A wrong
parameter name returns an empty list, not an error, so an empty result here is only a finding
once the same query has returned events for a window you know had some.

## Monitors

```bash
curl -sS \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v1/monitor/<MONITOR_ID>" \
| python3 -c 'import json,sys; m=json.load(sys.stdin); o=m.get("options",{}); print(m.get("name"), "| query:", m.get("query"), "| notify_no_data:", o.get("notify_no_data"), "| no_data_timeframe:", o.get("no_data_timeframe"))'
```

## Incidents

### Find open ones

```bash
curl -sS -G \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/incidents/search" \
  --data-urlencode 'query=state:(active OR stable)' \
  --data-urlencode 'page[size]=20'
```

### Create

Build the payload in a file, because narrative text contains quotes, `$` and newlines that break
a hand-quoted `--data` literal. Build, check and send in one Bash call so the temp path survives:

```bash
PAYLOAD=$(mktemp) && python3 - "$PAYLOAD" <<'PY' && \
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PAYLOAD" && \
curl -sS -w '\nHTTP %{http_code}\n' -X POST -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/incidents" --data @"$PAYLOAD"; rm -f "$PAYLOAD"
import json, sys

summary = "<symptom, first bad time, measured impact, 'cause not yet known'>"

payload = {"data": {"type": "incidents", "attributes": {
    "title": "<service>: <symptom>, cause unknown",
    "customer_impacted": True,
    "customer_impact_scope": "<who is affected and how, from the blast-radius block>",
    "fields": {
        "severity": {"type": "dropdown",    "value": "<SEV-2>"},
        "summary":  {"type": "textbox",     "value": summary},
        "services": {"type": "multiselect", "value": ["<SERVICE>"]},
    },
}}}
json.dump(payload, open(sys.argv[1], "w"))
PY
```

The `&&` chain means a generator that fails, or a file that does not parse, sends nothing: an
empty or truncated file sent with `--data @file` produces a `400` that reads like an API
problem.

- `title` and `customer_impacted` are required. `customer_impact_scope` is required when
  `customer_impacted` is `true`; omitting it fails the create.
- Everything else descriptive goes under `attributes.fields`, each as `{"type", "value"}`.
  Single-value types are `dropdown` and `textbox`; multi-value types are `multiselect`,
  `textarray`, `metrictag` and `autocomplete`. Which fields exist, and their allowed values,
  is per organization: `detection_method`, for example, exists only if the org defines it.
- The response has `data.id` (a UUID, used by every later call) and
  `data.attributes.public_id` (the short number in the UI). Keep both.
- Read the HTTP status before parsing the body. Incident responses have been seen to carry raw
  control characters that make a strict JSON parser fail; a `201` with a parse error means the
  incident exists. Re-read it rather than posting again, or you create a duplicate.

### Amend

```bash
curl -sS -w '\nHTTP %{http_code}\n' -X PATCH -H "Content-Type: application/json" \
  -H "DD-API-KEY: ${DD_API_KEY:?}" -H "DD-APPLICATION-KEY: ${DD_APPLICATION_KEY:?}" \
  "https://api.${DD_SITE:?}/api/v2/incidents/<INCIDENT_UUID>" --data @- <<'JSON'
{ "data": { "id": "<INCIDENT_UUID>", "type": "incidents", "attributes": {
    "detected": "<ISO8601 when a person or monitor first knew>",
    "customer_impact_start": "<ISO8601 impact start from the metric boundary>",
    "fields": { "state": { "type": "dropdown", "value": "<active|stable|resolved>" } }
} } }
JSON
```

`data.id` is required in the body as well as the URL. Updatable attributes include `title`,
`customer_impacted`, `customer_impact_scope`, `customer_impact_start`, `customer_impact_end`,
`detected` and `fields`. There is no public endpoint for adding timeline notes after creation;
`initial_cells` on create is the only API path into the timeline.

### Sub-resources

The paths are not uniform, and a wrong guess returns a `404` that reads like "feature
unavailable":

| Sub-resource | Path under `/api/v2/incidents/<INCIDENT_UUID>` |
|---|---|
| Follow-up todos | `/relationships/todos` |
| Attachments | `/attachments` |
| Impacts | `/impacts` |
| Responders | `/responders` |
| Integrations (chat channel, tickets) | `/relationships/integrations` |

## Verify against current docs

Request shapes checked on 2026-09-25 against the OpenAPI specs in
DataDog/datadog-api-client-typescript (`.generator/schemas/v1/openapi.yaml`,
`.generator/schemas/v2/openapi.yaml`). The Incidents list, search and create endpoints are
marked public beta there; Error Tracking and `validate_keys` are recent additions. Re-check a
shape against docs.datadoghq.com/api/latest/ when a call returns `400` or `404`.
