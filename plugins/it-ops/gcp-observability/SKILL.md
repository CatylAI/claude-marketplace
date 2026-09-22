---
name: gcp-observability
description: "Google Cloud adapter for incident response and production triage. Use when an incident, error sweep or blast-radius question has to be answered against a GCP project — Cloud Logging, Cloud Monitoring, Error Reporting, Cloud Trace, Cloud Build, Cloud Deploy and Cloud Audit Logs. Supplies the concrete gcloud commands and API calls that observability-core deliberately leaves abstract."
license: MIT
user-invocable: false
---

# GCP Observability

`observability-core` writes every procedure against **capabilities** — an error
aggregator, a metrics store, a deploy log, an incident record — and ends by asking you to
map those capabilities once per environment. This plugin is that mapping, filled in for
Google Cloud, plus the queries.

The judgement stays in the core. Nothing here changes when to declare, how severity is
chosen, or what ranks above what in a triage sweep. This layer only answers *how do I get
that number out of GCP*.

## The capability table, filled in

| Capability | GCP service | How you reach it |
|------------|-------------|------------------|
| Error aggregator | Cloud Error Reporting | `projects.groupStats.list` for the aggregate, `projects.events.list` for raw events — both REST only. `gcloud beta error-reporting` can report and delete events but cannot read them. Cloud Logging is the fallback aggregator when a service does not report into Error Reporting. |
| Metrics store | Cloud Monitoring | `projects.timeSeries.list` (v3), or PromQL / MQL through the query endpoints. Request rate, error rate and latency distributions live here, not in Logging. |
| Deploy / change log | Cloud Build, Cloud Deploy, **and** Cloud Audit Logs | `gcloud builds list`, `gcloud deploy releases list` / `rollouts list`, `gcloud run revisions list`, plus the Admin Activity audit log for every change that did not go through a pipeline. |
| Incident record | **Not a GCP product.** | GCP has no incident-record service. Cloud Monitoring *incidents* are alert-policy state, not an incident record — they carry no severity, no roles, no timeline and no narrative. The declaration artifact lives in your incident tool or a shared document, outside this plugin. |
| Work tracker | **Not a GCP product.** | Pair this plugin with a tracker adapter. Error Reporting group links go into tracker items; the items themselves are filed elsewhere. |
| Comms channel | **Not a GCP product.** | Your chat platform. Cloud Monitoring notification channels can page into it, but they do not coordinate a response. |

Three of six capabilities have no GCP answer. That is not a gap to paper over — it is the
honest shape of the platform, and the core's rule applies: **an unmeasured dimension is an
unknown, not a zero.** If nobody can point at where the incident record lives, say so
during the incident rather than letting the absence pass as "we did not need one".

## Precondition: an authenticated `gcloud`

Every command in this plugin runs through the `gcloud` CLI against a project you can
already read. Confirm both before you start querying, because an expired credential and a
genuinely quiet system return the same thing: nothing.

```
gcloud auth list
gcloud config get-value project
```

If the active account is wrong, or the project is unset, fix that first. A responder who
does not verify this ends up reporting an empty result set as a clean system.

Read-only response needs `roles/logging.viewer`, `roles/monitoring.viewer` and
`roles/errorreporting.viewer` at minimum. Data Access audit logs additionally need
`roles/logging.privateLogViewer`.

Throughout, `<PROJECT_ID>`, `<SERVICE>`, `<REGION>` and similar are placeholders.
Substitute your own; never paste a project id from an example.

## What is in here

| Component | Type | Use when |
|-----------|------|----------|
| `gcp-incident-response` | Skill | Confirming production impact, measuring blast radius on GCP, and correlating against what shipped in the last 24 hours. |
| `gcp-log-queries` | Skill | You need a working Cloud Logging filter right now — the mid-incident cookbook. |
| `gcp-prod-triage` | Skill | Sweeping a window of production errors into a ranked, deduplicated proposal set. |
| `gcp-investigator` | Subagent | A specific, bounded investigative question you want answered read-only, without the main session spending its context on query output. Claude Code only. |

## Not this plugin's job

- **Postmortems.** The `incident-postmortem` skill in the `ops-workflows` plugin owns the
  blameless write-up, the timeline format and the action-item table. This plugin, like the
  core it adapts, covers the live phase and stops at resolution.
- **The judgement about when to declare, what severity means, and how to rank a triage
  sweep.** That is `observability-core`. If you find yourself deciding *whether* something
  is an incident from a GCP query result, you are in the wrong layer — read
  `incident-declaration` and `blast-radius` first, then come back here for the numbers.
- **Mutating anything.** Nothing in this plugin scales a service, rolls back a revision,
  deletes a resource, or mutes an error group on its own authority. Where an action is
  implied, the skill says so and stops.
- **Other clouds.** The procedures in the core are portable; these queries are not. A
  different cloud needs a different adapter.
