# gcp-observability

The Google Cloud adapter for `observability-core`. It fills in the capability table that
the core leaves blank, and supplies the concrete Cloud Logging, Cloud Monitoring, Error
Reporting, Cloud Build, Cloud Deploy and Cloud Audit Log queries that the core
deliberately refuses to name.

Works in **Claude Code** and in **Cowork** (Claude Code on the web) — with an important
caveat about shell access, below.

## What it is

`observability-core` writes every incident procedure against capabilities rather than
products: an error aggregator, a metrics store, a deploy log, an incident record. That is
what lets it survive a change of telemetry vendor. It ends by asking you to map those
capabilities once, per environment.

This plugin is that mapping for Google Cloud, plus the commands. The judgement stays in
the core — when to declare, how severity is read off measured impact, what ranks above
what in a triage sweep. Nothing here changes any of it. This layer only answers *how do I
get that number out of GCP*.

## When to use it

- Production is degraded or broken in a GCP project and you need to confirm impact fast.
- Severity is being argued about and nobody has produced a number yet.
- You need to know what shipped in the last 24 hours across Cloud Build, Cloud Deploy and
  Cloud Audit Logs.
- You need a working Cloud Logging filter right now, or a query is returning nothing and
  you cannot tell whether the system is clean or the filter is wrong.
- You are sweeping a window of production errors into a ranked, deduplicated set of
  proposed work items.

## When not to use it

- **You are deciding *whether* something is an incident.** That is `observability-core`'s
  `incident-declaration`. Read it first; come back here for the numbers.
- **The incident is resolved and you are writing it up.** Postmortems belong to the
  `incident-postmortem` skill in the `ops-workflows` plugin — the blameless write-up, the
  timeline format, the action-item table. This plugin, like the core, covers the live
  phase and stops at resolution.
- **You want something changed.** Nothing here scales a service, rolls back a revision, or
  mutes an error group. Where an action is implied, the skill recommends it and stops.
- **You are on a different cloud.** The core's procedures are portable; these queries are
  not.

## Prerequisites

An installed `gcloud` CLI, authenticated against a project you can read. Verify both
before you start querying, because an expired credential and a genuinely quiet system
return the same empty output:

```
gcloud auth list
gcloud config get-value project
```

If the active account is wrong or the project is unset, fix that before reading any result
as meaningful.

### IAM roles for a read-only responder

| Role | Grants |
|------|--------|
| `roles/logging.viewer` | Read log entries, including Admin Activity audit logs. |
| `roles/monitoring.viewer` | Read metrics, time series, alert policies and dashboards. |
| `roles/errorreporting.viewer` | Read error groups, group stats and events. |

Two additions depending on what you need to reach:

- `roles/logging.privateLogViewer` — required to read **Data Access** audit logs. Admin
  Activity logs are covered by `roles/logging.viewer`; Data Access logs are not, and are
  also off by default.
- `roles/cloudtrace.user` — required to read Cloud Trace spans. Verify against your own
  organization's role policy; trace roles are the least standardised of the set.

None of these grant write access, which is the point: the whole plugin, and the
`gcp-investigator` subagent in particular, is designed to work from a read-only identity.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install gcp-observability@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `gcp-incident-response` | Skill | Confirm production impact in three queries, measure blast radius across users/requests/tenants/regions/time, correlate against builds, rollouts and audit-log configuration changes | both |
| `gcp-log-queries` | Skill | Cloud Logging cookbook: `gcloud logging read` anatomy, the query language, ready-to-paste filters, log-based metrics, quota hazards, and when to query a sink instead | both |
| `gcp-prod-triage` | Skill | Error Reporting `groupStats` before `events`, ranking by blast radius and novelty, deduplication, and a proposal set for a tracker adapter to file | both |
| `gcp-investigator` | Subagent | Answers one bounded investigative question read-only and reports the literal commands it ran, what it found, and what it could not determine | Claude Code only |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**Subagents are Claude Code only.** `gcp-investigator` is unavailable in Cowork; the
skills above are not. There is a second caveat specific to this plugin: **every skill here
drives the `gcloud` CLI, and Cowork has no checkout and no shell.** The skills are fully
readable on the web surface — the filters, the API parameters, the ranking rules and the
reporting formats are all text — but they are only *executable* where a shell and an
authenticated `gcloud` exist, which in practice means Claude Code.

## Layout

```
gcp-observability/
├── .claude-plugin/plugin.json            # manifest (name, version, description, dependencies)
├── SKILL.md                              # plugin entry point; the filled-in capability table
├── skills/
│   ├── gcp-incident-response/SKILL.md    # impact confirmation, blast radius, change correlation
│   ├── gcp-log-queries/SKILL.md          # Cloud Logging cookbook
│   └── gcp-prod-triage/SKILL.md          # Error Reporting sweep and proposal set
├── agents/
│   └── gcp-investigator.md               # read-only subagent; Claude Code only
└── README.md
```

## The `observability-core` seam

The core's final section asks you to write down the local answer to six capabilities.
Here they are for Google Cloud:

| Capability | GCP service |
|------------|-------------|
| Error aggregator | Cloud Error Reporting (`projects.groupStats.list` for aggregates, `events.list` for raw); Cloud Logging as the fallback for services that do not report into it |
| Metrics store | Cloud Monitoring — `projects.timeSeries.list`, or PromQL / MQL through the query endpoints |
| Deploy / change log | Cloud Build, Cloud Deploy, Cloud Run revisions, **and** Cloud Audit Logs for every change that did not go through a pipeline |
| Incident record | **Not a GCP product.** Cloud Monitoring "incidents" are alert-policy state — no severity, no roles, no timeline, no narrative. The declaration artifact lives in your incident tool or a shared document. |
| Work tracker | **Not a GCP product.** Pair with a tracker adapter; this plugin proposes items, it does not file them. |
| Comms channel | **Not a GCP product.** Your chat platform. Monitoring notification channels can page into it; they do not coordinate a response. |

Three of six have no GCP answer, and that is reported rather than hidden. The core's rule
carries through this entire plugin: **if a capability has no local answer, say so out loud
during the incident — an unmeasured dimension is an unknown, not a zero.** You will find
the same rule applied to `affectedUsersCount: 0`, to zero-row log queries, and to every
`NOT MEASURED` slot in the blast-radius reporting block.

## Dependencies

- `observability-core` — the vendor-neutral incident discipline this plugin adapts.
  Install it; without it you have queries and no procedure.

## License

MIT
