# Datadog setup: capability rows, transport, credentials

Contents

- [Capability rows for the project's CLAUDE.md](#capability-rows-for-the-projects-claudemd)
- [Transport, in order of preference](#transport-in-order-of-preference)
- [MCP tool map](#mcp-tool-map)
- [REST credentials and site](#rest-credentials-and-site)
- [Checking access before trusting a result](#checking-access-before-trusting-a-result)
- [Permissions](#permissions)
- [Verify against current docs](#verify-against-current-docs)

## Capability rows for the project's CLAUDE.md

`observability-core` reads a `## Observability capabilities` section from the project's
`CLAUDE.md` (template: `observability-core`'s `incident-declaration` skill,
`references/capabilities.md`). For a Datadog organization, these are the rows to offer. Replace
every `<…>`; keep a row and write `none` when it does not apply.

```markdown
## Observability capabilities

| Capability | Where and how | Notes |
|---|---|---|
| Vendor adapter | datadog-observability | Datadog site: <datadoghq.com / datadoghq.eu / us3.datadoghq.com / …> |
| Error aggregator | Datadog Error Tracking (issues); fallback: log aggregation on <@error.kind> | Services not reporting into Error Tracking: <list> |
| Metrics store | Datadog Metrics, including APM trace metrics `trace.<operation>.hits` / `.errors` | Operation names per service: <list> |
| Production tag | <env:production> | Reserved `env` tag, not the `@env` log attribute; confirmed returning data on <logs / spans / metrics> |
| Deploy and change log | `version` tag (deployment tracking); Datadog Events; Datadog Audit Trail for Datadog config edits; <sources outside Datadog: flag provider, cloud audit log> | |
| Known gaps | <log indexes with exclusion filters or daily quotas; services without APM; paths with no user ID> | |
| Incident record | Datadog Incident Management | Severity values: <SEV-1…SEV-5>; statuses: <active, stable, resolved[, completed]> |
| Work tracker | <not Datadog: tracker, project, intake state> | Datadog incident todos and Case Management link to it; they are not the backlog |
| Comms channel | <chat channel>; paging: <Datadog On-Call / other> | |
```

Datadog fills more rows than most stacks: it has a real incident record, so the declaration
lives in the same system as the evidence. It is not a work tracker, and the coordination half
of comms lives in chat even when On-Call does the paging.

## Transport, in order of preference

1. **Datadog MCP tools.** If the session has tools such as `search_datadog_logs` or
   `get_datadog_metric` (whatever prefix the client gives them), use them. Datadog runs the
   server; OAuth or key auth and the site are handled at setup. Ways to get them:
   - Claude Code: Datadog's plugin, `/plugin install datadog@claude-plugins-official`, then
     `/ddsetup` (site and login) and `/ddtoolsets` (enable `error-tracking` for triage).
   - Claude apps, including Cowork: the Datadog connector from the Claude connectors directory.
   - Any other MCP client: the remote endpoint for your site from Datadog's MCP setup page.
     Datadog's docs ask you to remove a manually added server when you install the plugin, so
     use one or the other.
2. **REST with curl** when no Datadog MCP tools are present but a shell, the keys and egress
   to `api.<site>` are. Calls are in `rest-api.md` beside this file.
3. **Pasted data** when neither works: ask the user for exports, screenshots transcribed to
   numbers, or counts, and label every number "pasted".

The MCP server has no tool that creates or updates an incident, so declaring and amending the
incident record uses REST or the Datadog UI even when MCP handles every read.

## MCP tool map

| Task | MCP tool (toolset) | REST fallback (`rest-api.md`) |
|---|---|---|
| Metric timeseries | `get_datadog_metric` (core) | Metrics: timeseries |
| Which metrics a service emits | `search_datadog_metrics`, `get_datadog_metric_context` (core) | Metrics: list a service's metrics |
| Log samples | `search_datadog_logs` (core) | Logs: search |
| Log counts, groupings, distinct users | `analyze_datadog_logs` (core) | Logs: aggregate |
| Spans | `search_datadog_spans` (core) | not covered here |
| Events (deploys, config, alerts) | `search_datadog_events` (core) | Events |
| Monitors | `search_datadog_monitors` (core) | Monitors |
| Incidents, read | `search_datadog_incidents`, `get_datadog_incident` (core) | Incidents: find open ones |
| Incidents, declare and amend | none | Incidents: create, amend |
| Error Tracking issues | `search_datadog_error_tracking_issues`, `get_datadog_error_tracking_issue` (error-tracking) | Error Tracking: search |
| Error samples, by version or type | `analyze_datadog_error_tracking_errors` (error-tracking) | Logs: aggregate (error logs only) |
| Datadog config edits | `search_audit_events` (audit-trail) | not covered here |

`error-tracking` and `audit-trail` are not in the default `core` toolset; enable them
explicitly.

## REST credentials and site

Three environment variables, set before the session starts, never written into a file or a
command literal:

| Variable | Holds |
|---|---|
| `DD_API_KEY` | API key |
| `DD_APPLICATION_KEY` | Application key. Reads need it; an API key alone authenticates submission, not query |
| `DD_SITE` | The site, for example `datadoghq.com`, `datadoghq.eu`, `us3.datadoghq.com`, `us5.datadoghq.com`, `ap1.datadoghq.com`. The API host is `api.` + site |

These are the names Datadog's own plugin reads for key authentication, so one set serves both.
Earlier versions of this plugin used `DD_APP_KEY`; rename it.

Shell variables do not persist between Bash tool calls, but environment variables exported
before the session do. So every block in `rest-api.md` reads the three variables directly and
fails loudly (`${VAR:?}`) when one is unset, instead of sending an unauthenticated request whose
error looks like a finding.

The site is part of the hostname. A valid key pair sent to the wrong site's host fails to
authenticate or returns empty results, and neither response says "wrong region". The MCP
server does not support the government sites (`ddog-gov.com`, `us2.ddog-gov.com`); use REST
there.

## Checking access before trusting a result

An expired key and a quiet system can both produce empty output. Confirm access first:

- **MCP:** run one read that must return data, such as `search_datadog_monitors` for the
  service's monitors, or a metric the service certainly emits. An auth or site error says the
  connection is wrong; an empty result on a known-busy service says the scope is wrong.
- **REST:** `GET /api/v2/validate_keys` checks both keys together (`rest-api.md`, Credential
  check). `GET /api/v1/validate` checks only the API key, so a missing or wrong application key
  passes it and then fails every read with a `403` that looks like a permissions problem.

## Permissions

- MCP tools need the Datadog role permission `mcp_read` (reads) or `mcp_write` (writes) plus the
  product permission, for example Monitors Read. A role without `mcp_write` makes the server
  reject every write tool, which is the reliable way to keep an investigation read-only.
- REST reads need the product read permissions; declaring an incident needs `incident_write`,
  and changing an Error Tracking issue needs Error Tracking write.
- A `403` on a read with both keys present usually means the application key's user or service
  account lacks that product's read permission. Report which call failed; do not report the
  missing data as zero.

## Verify against current docs

Checked on 2026-09-25 against Datadog's MCP server docs (docs.datadoghq.com/mcp_server/,
`/setup`, `/tools`), the datadog-labs/claude-code-plugin README, and the OpenAPI specs in
DataDog/datadog-api-client-typescript (`.generator/schemas/v1|v2/openapi.yaml`). Re-check these
before relying on them:

- The Incidents create, list and search endpoints are marked public beta (`x-unstable`).
- `GET /api/v2/validate_keys` is new; if it returns `404`, use `GET /api/v2/current_user`
  (needs both keys, no extra permission) as the application-key check.
- Datadog describes its MCP tools as under significant development; tool names and toolsets
  change. The plugin is marked Preview.
- MCP fair-use limits exist per organization; heavy sweeps can hit them.
