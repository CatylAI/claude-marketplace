# gcp-observability

The Google Cloud adapter for `observability-core`. The core plugin owns the incident procedure:
when to declare, severity, the blast-radius block, triage ranking and filing. This plugin says
where each of those numbers lives in a GCP project, how to read it (Google's MCP servers first,
`gcloud` and REST as the fallback, pasted data when neither is available), and which GCP
behaviours make the number wrong.

## What ships

| Name | Type | Purpose | Surfaces |
|---|---|---|---|
| `gcp-incident-response` | Skill | Confirm impact in three reads, fill the core blast-radius block from GCP sources, and check what changed across Cloud Build, Cloud Deploy, Cloud Run revisions and the Admin Activity audit log | Claude Code, Cowork |
| `gcp-log-queries` | Skill | Cloud Logging query language, the `--freshness` trap, zero-row checks, when to query a sink; ready-made filters in `references/filters.md` | Claude Code, Cowork |
| `gcp-prod-triage` | Skill | Error Reporting inputs for the core triage loop: group stats across all regions, GCP field mapping, merge tells, group status proposals | Claude Code, Cowork |
| `gcp-investigator` | Agent | Answers one bounded question read-only and returns the commands it ran, findings, gaps and a confidence level | Claude Code only |

Shared reference files, in `skills/gcp-incident-response/references/`:

- `setup.md`: the GCP-filled rows for your project's `## Observability capabilities` section,
  the map from each read to its MCP tool and CLI or REST fallback, and the IAM roles.
- `rest-fallback.md`: Monitoring (filters and PromQL), Error Reporting and Trace REST calls, and
  what `gcloud` can and cannot read.

## When to use it

- A service in a GCP project is degraded and you need to confirm impact and put a number on
  severity.
- You need to know what changed in the project, including console changes that no pipeline
  recorded.
- A Cloud Logging query returns nothing and you cannot tell whether the system is clean or the
  query is wrong.
- You are sweeping a window of GCP production errors into proposed work items.

## When not to use it

- Deciding whether something is an incident, or what severity means:
  `observability-core:incident-declaration` and `observability-core:blast-radius`.
- The write-up after resolution: `ops-workflows:incident-postmortem`.
- Changing anything. The skills and the agent only read; where an action is implied they write
  down the command for someone with write access.
- Other clouds.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install gcp-observability@catylai
```

This also installs `observability-core`, which it depends on.

**claude.ai:** enable the plugin for your claude.ai account. Claude Code then loads it as a
synced plugin (`gcp-observability@synced`).

## Tell it about your project

Add a `## Observability capabilities` section to your project's `CLAUDE.md`, as described in
`observability-core`. The GCP rows are pre-filled in
`skills/gcp-incident-response/references/setup.md`; the skills also offer to write them after an
incident or sweep. The incident record, work tracker and comms channel are not GCP products, so
those rows are yours to fill in.

## Connecting to Google Cloud

The skills use the first of these that works.

### 1. Google's MCP servers (recommended)

- **Remote servers run by Google:** Cloud Logging, Cloud Monitoring, and, in Preview, Error
  Reporting and Cloud Trace. Each has an HTTP endpoint of the form
  `https://<service>.googleapis.com/mcp` and uses OAuth with IAM. The caller needs
  `roles/mcp.toolUser` on the project in addition to the read roles below. Setup, including the
  OAuth client for Claude, is in Google's "Configure MCP in an AI application" guide
  (docs.cloud.google.com/mcp/configure-mcp-ai-application) and the per-product pages
  (for example docs.cloud.google.com/logging/docs/use-logging-mcp and
  docs.cloud.google.com/monitoring/docs/use-monitoring-mcp).
- **Local server:** `@google-cloud/observability-mcp` from `googleapis/gcloud-mcp`, run with
  `npx -y @google-cloud/observability-mcp`. It uses Application Default Credentials
  (`gcloud auth application-default login`) and a quota project that has the Logging,
  Monitoring, Trace and Error Reporting APIs enabled. It is marked preview by its maintainers.

The plugin ships no `.mcp.json`, because the remote servers need your own OAuth client and the
local one needs your credentials. Add each server with `claude mcp add` under the name below. The
skills work with any name, because they look for the tool names (`list_log_entries`,
`list_timeseries` or `list_time_series`, `list_group_stats`). The `gcp-investigator` agent is
stricter: its tool list allows only these server names, so a server added under another name is
invisible to it and it falls back to `gcloud`.

| Server | Name to use |
|---|---|
| Google remote Logging MCP | `gcp-logging` |
| Google remote Monitoring MCP | `gcp-monitoring` |
| Google remote Error Reporting MCP | `gcp-error-reporting` |
| Google remote Trace MCP | `gcp-trace` |
| Local `@google-cloud/observability-mcp` | `gcp-observability` |

### 2. gcloud and REST

An installed, authenticated `gcloud` (`gcloud auth list`, `gcloud config get-value project`).
Logging, builds, rollouts and revisions are read with `gcloud`; Monitoring, Error Reporting and
Trace have no `gcloud` read command, so the skills use REST with
`gcloud auth print-access-token`.

### 3. Pasted data

With neither, the skills ask you to paste console exports (request counts by status class, the
Error Reporting list, log entries) and label every number `pasted`.

### IAM roles for a read-only identity

| Role | Grants |
|---|---|
| `roles/logging.viewer` | Log entries, including Admin Activity audit logs |
| `roles/logging.privateLogViewer` | Data Access audit logs (also off by default per service) |
| `roles/monitoring.viewer` | Time series, alert policies, dashboards |
| `roles/errorreporting.viewer` | Error groups, group stats, events |
| `roles/cloudtrace.user` | Trace data |
| `roles/mcp.toolUser` | Calling Google's remote MCP servers |

## Surfaces

- **Claude Code** on your machine: everything works, with whichever of the three connections
  you have.
- **Claude Code on the web** runs in a cloud container with a shell. What it usually lacks is
  `gcloud` credentials and network access to `*.googleapis.com`; both are environment settings.
  Without them, use Google's MCP servers if connected, or pasted data.
- **Cowork and the claude.ai apps:** the three skills load and work through connectors or
  pasted data.
- **`gcp-investigator` is Claude Code only**, as plugin agents are. The plugin still uses an
  agent here because an investigation can take dozens of queries whose raw
  output would otherwise fill the main session's context. On other surfaces, use the skills
  directly.

The agent's tool list is Bash, Read, Grep and the five Google Cloud MCP server names in the
table above; Write, Edit and NotebookEdit are disallowed. A server added under another name is
invisible to it. It stays read-only by instruction; for a guarantee, add deny rules for `gcloud` write verbs in your permission settings, and allow rules
such as `Bash(gcloud logging read *)` to avoid prompts.

## Layout

```
gcp-observability/
├── .claude-plugin/plugin.json
├── README.md
├── agents/
│   └── gcp-investigator.md
└── skills/
    ├── gcp-incident-response/
    │   ├── SKILL.md
    │   └── references/
    │       ├── setup.md
    │       └── rest-fallback.md
    ├── gcp-log-queries/
    │   ├── SKILL.md
    │   └── references/filters.md
    └── gcp-prod-triage/SKILL.md
```

## Dependencies

- `observability-core`: the procedures, reporting block and templates this plugin fills in.

## License

MIT
