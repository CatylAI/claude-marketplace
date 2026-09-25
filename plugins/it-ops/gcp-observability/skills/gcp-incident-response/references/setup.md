# GCP setup: capability rows, transport map, access

Shared by every skill in `gcp-observability`.

- [Capability rows for the project CLAUDE.md](#capability-rows-for-the-project-claudemd)
- [Transport map](#transport-map)
- [Access: credential check and IAM roles](#access-credential-check-and-iam-roles)

## Capability rows for the project CLAUDE.md

`observability-core` reads a `## Observability capabilities` section from the project's
`CLAUDE.md` (template: `observability-core`'s `incident-declaration` skill,
`references/capabilities.md`). For a GCP project, offer these rows and replace every `<…>`. The
last four have no GCP answer; ask the user for them.

```markdown
## Observability capabilities

| Capability | Where and how | Notes |
|---|---|---|
| Vendor adapter | gcp-observability | |
| Error aggregator | Cloud Error Reporting, project <PROJECT_ID>, read with list_group_stats on projects/<PROJECT_ID>/locations/- | Cloud Logging for services that do not report into Error Reporting |
| Metrics store | Cloud Monitoring, project <PROJECT_ID> (filters or PromQL) | request_count, request_latencies per service |
| Deploy and change log | Cloud Build, Cloud Deploy pipeline <PIPELINE>, Cloud Run revisions, Admin Activity audit log | Data Access audit logs: <on for which services / off> |
| Known gaps | <services not reporting to Error Reporting; logs excluded or routed to other buckets or sinks> | |
| Production tag | <e.g. project <PROJECT_ID>, or a label such as labels.env="prod"> | Confirm it returns data |
| Incident record | <incident tool or document location> | Not a GCP product |
| Work tracker | <tracker, project and intake state> | Not a GCP product |
| Comms channel | <chat channel> | Monitoring notification channels can page into it |
```

Offer to add the section after the incident or sweep, and write it only when the user agrees.

## Transport map

Use the first available column. MCP tool names appear with the server prefix the user chose
(for example `mcp__<server>__list_log_entries`). Tool names verified against Google's MCP
reference pages and the `@google-cloud/observability-mcp` README; verify against current docs,
since the remote Error Reporting and Trace servers are in Preview.

| Read | Google remote MCP server | Local `@google-cloud/observability-mcp` | CLI or REST fallback |
|---|---|---|---|
| Log entries | `list_log_entries` (Logging) | `list_log_entries` | `gcloud logging read` |
| Log sinks | not listed | `list_sinks` | `gcloud logging sinks list` |
| Buckets and views | `list_buckets`, `list_views` | `list_buckets`, `list_views` | `gcloud logging buckets list` |
| Time series | `list_timeseries` (Monitoring) | `list_time_series` | REST `timeSeries.list` or PromQL, [rest-fallback.md](rest-fallback.md) |
| Metric names | `list_metric_descriptors` | `list_metric_descriptors` | REST `metricDescriptors.list` |
| Error groups | `list_group_stats` (Error Reporting, Preview) | `list_group_stats` | REST `groupStats.list`, [rest-fallback.md](rest-fallback.md) |
| Traces | `get_trace` (Trace, Preview) | `list_traces`, `get_trace` | REST, [rest-fallback.md](rest-fallback.md) |
| Builds, rollouts, revisions | not covered | not covered | `gcloud builds`, `gcloud deploy`, `gcloud run revisions` |

Behaviour that differs from gcloud:

- `list_log_entries` takes one project in `resourceNames` and has no `--freshness`: put a
  `timestamp>=` clause in the filter, and set `orderBy` and `pageSize`.
- `list_group_stats` takes `projectName`; pass `projects/<PROJECT_ID>/locations/-` so regional
  errors are included.
- The local server uses Application Default Credentials and a quota project that must have each
  API enabled.

## Access: credential check and IAM roles

With gcloud, check before the first read, because an expired credential and a quiet system both
return empty output:

```
gcloud auth list
gcloud config get-value project
```

With MCP, the first call against the named project is the check: an auth or permission error
means the dimension is `NOT MEASURED`, not zero.

| Role | Grants |
|---|---|
| `roles/logging.viewer` | Log entries, including Admin Activity audit logs |
| `roles/logging.privateLogViewer` | Data Access audit logs (also off by default per service) |
| `roles/monitoring.viewer` | Time series, alert policies, dashboards |
| `roles/errorreporting.viewer` | Error groups, group stats, events |
| `roles/cloudtrace.user` | Trace data; check your organization's role policy |
| `roles/mcp.toolUser` | Calling Google's remote MCP servers, in addition to the roles above |

None of these grant writes, and the skills and `gcp-investigator` are written for a read-only
identity.
