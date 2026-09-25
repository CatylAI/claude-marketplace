# Ready-made Cloud Logging filters

Each filter works in `gcloud logging read` as shown, or in `list_log_entries` with the
`--freshness` window rewritten as a `timestamp>="<WINDOW_START>"` clause.

- [5xx from one Cloud Run service](#5xx-from-one-cloud-run-service)
- [Uncaught exceptions by service](#uncaught-exceptions-by-service)
- [One request across every service](#one-request-across-every-service)
- [GKE container logs for one pod](#gke-container-logs-for-one-pod)
- [Load balancer request logs](#load-balancer-request-logs)
- [Follow-up: turning a filter into a log-based metric](#follow-up-turning-a-filter-into-a-log-based-metric)

## 5xx from one Cloud Run service

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=50 --order=desc \
  --format='table(timestamp, httpRequest.status, httpRequest.requestUrl, resource.labels.revision_name)'
```

`revision_name` makes this a deploy correlation: if every 5xx carries one revision and the
previous revision has none, that revision is the lead.

## Uncaught exceptions by service

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND severity>=ERROR
   AND (jsonPayload.stack_trace:* OR textPayload:"Traceback" OR textPayload:"Exception")' \
  --project=<PROJECT_ID> --freshness=6h --limit=100 --order=desc \
  --format='value(resource.labels.service_name)' | sort | uniq -c | sort -rn
```

A rough substitute for Error Reporting's grouping, for services that do not report into it.
Record the source as `logs`.

## One request across every service

Get a trace ID from a failing request:

```
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="<SERVICE>"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=1 --format='value(trace)'
```

Then read every entry that shares it, oldest first, with the bound in the filter because the
read is ascending:

```
gcloud logging read \
  'trace="projects/<PROJECT_ID>/traces/<TRACE_ID>"
   AND timestamp>="<WINDOW_START>"' \
  --project=<PROJECT_ID> --limit=200 --order=asc \
  --format='table(timestamp, resource.labels.service_name, severity, jsonPayload.message, textPayload)'
```

There is no `resource.type` clause, so the read crosses service boundaries; the last entry
before the error usually names the hop that failed. Structured logs written by client libraries
carry the same value as `logging.googleapis.com/trace`. An empty `trace` field means trace
context is not propagated; report that gap rather than rebuilding the path from timestamps.
Cloud Trace (`get_trace`, or the REST call in
`skills/gcp-incident-response/references/rest-fallback.md`) shows where the time went.

## GKE container logs for one pod

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

For scheduling, evictions and OOM kills, query `resource.type="k8s_pod"` and
`resource.type="k8s_node"`. A container that stops logging with no error is usually explained
there.

## Load balancer request logs

```
gcloud logging read \
  'resource.type="http_load_balancer"
   AND httpRequest.status>=500' \
  --project=<PROJECT_ID> --freshness=1h --limit=100 --order=desc \
  --format='table(timestamp, httpRequest.status, httpRequest.requestUrl, jsonPayload.statusDetails, resource.labels.backend_service_name)'
```

`jsonPayload.statusDetails` says whether the load balancer reached the service:
`failed_to_connect_to_backend` and `backend_timeout` put the fault in front of the service;
`response_sent_by_backend` means the service itself answered 5xx. Request logging can be off or
sampled per backend service, so confirm it before reading an empty result as no traffic.

## Follow-up: turning a filter into a log-based metric

A filter you run repeatedly, or want to alert on or chart beside request volume, can become a
counter. This is a write, so it belongs in the follow-ups after an incident, done by someone
with write access; the skills and `gcp-investigator` do not run it.

```
gcloud logging metrics create <METRIC_NAME> \
  --project=<PROJECT_ID> \
  --description="5xx responses from <SERVICE>" \
  --log-filter='resource.type="cloud_run_revision"
                AND resource.labels.service_name="<SERVICE>"
                AND httpRequest.status>=500'
```

It appears in Monitoring as `logging.googleapis.com/user/<METRIC_NAME>`. It counts only from
creation, so it tells you nothing about an incident already under way. Label it only on bounded
dimensions (service, region, status class); a user or request ID label makes it unusable and
expensive.
