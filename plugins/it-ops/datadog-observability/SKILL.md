---
name: datadog-observability
description: "Datadog adapter for incident response and production triage. Use when an incident, error sweep or blast-radius question has to be answered against a Datadog organization — Log Management, Error Tracking, Metrics, APM spans and trace metrics, Monitors, Events and deployment tracking, Incident Management and On-Call. Supplies the concrete API calls and query syntax that observability-core deliberately leaves abstract."
license: MIT
user-invocable: false
---

# Datadog Observability

`observability-core` writes every procedure against **capabilities** — an error
aggregator, a metrics store, a deploy log, an incident record — and ends by
asking you to map those capabilities once per environment. This plugin is that
mapping, filled in for Datadog, plus the queries.

The judgement stays in the core. Nothing here changes when to declare, how
severity is chosen, or what ranks above what in a triage sweep. This layer only
answers *how do I get that number out of Datadog*.

## The capability table, filled in

| Capability | Datadog product | How you reach it |
|------------|-----------------|------------------|
| Error aggregator | **Log Management** and **Error Tracking** | `POST /api/v2/logs/analytics/aggregate` groups log events by facet and counts them. Error Tracking goes further and does the clustering for you: it groups stack traces into durable *issues* with a first-seen, a last-seen and an affected-user count, across both APM errors and error logs. Start at the issue list, drop to raw events only for the top few. |
| Metrics store | **Metrics**, including APM trace metrics | `GET /api/v1/query` for a timeseries. Request rate, error rate and latency percentiles live here, not in logs. The `trace.*` metric family is generated from spans and is where a denominator with the same shape as your error count comes from. |
| Deploy / change log | **Events**, plus **deployment tracking** on the `version` tag | `GET /api/v2/events` (or the v1 event stream) for anything that emitted an event — CI, config management, cloud-provider integrations. Deployment tracking correlates a `version` tag change against a service's own metrics, which is the correlation you actually want. Neither is complete on its own; see below. |
| Incident record | **Incident Management.** A real product. | `POST /api/v2/incidents` declares one; `PATCH` amends it as evidence arrives. It carries severity, state, a detection method and time, services, responders, impacts, timeline notes, follow-up todos and attachments. This is a genuine difference from clouds that have no such product — see the note below. |
| Work tracker | **Not a work tracker.** | Datadog has Case Management and incident follow-up todos, and both are useful *inside* Datadog — but neither is a backlog with owners, priorities, iterations and a change history that the engineering team plans from. Pair this plugin with a tracker adapter. Follow-ups become tracked items there and are linked back from the incident. |
| Comms channel | **Not a Datadog product** — with one real exception. | The conversation lives in your chat platform. Datadog's chat integrations can post monitor notifications and open an incident channel, and **Datadog On-Call is a real paging product**, so the *notification* half of comms is in Datadog and the *coordination* half is not. |

**Four of six have a Datadog answer, and one of the two that do not is partial.**
That is a materially better fill than a cloud-native stack: the sibling
`gcp-observability` adapter records "not a GCP product" against the incident
record, the work tracker and the comms channel, three of six, because Google
Cloud has no incident-management product at all — Cloud Monitoring's "incidents"
are alert-policy state transitions with no severity, no roles, no timeline and no
narrative.

Datadog does have the product, and the difference is worth stating rather than
glossing: **the declaration artifact `incident-declaration` asks for can live in
the same system as the evidence.** That removes the most common excuse for
declaring late, which is that the incident tool is somewhere else and opening it
is a context switch. It also introduces a failure mode the GCP adapter cannot
have — an incident record that exists, is linked from everywhere, and is *empty*,
which reads a quarter later exactly like no incident at all. The
`datadog-incident-response` skill is largely about not producing that.

The core's rule applies to the remaining gaps as written: **if a capability has
no local answer, say so out loud during the incident. An unmeasured dimension is
an unknown, not a zero.** If nobody can point at where the follow-ups will be
tracked, say so rather than letting incident todos stand in for a backlog.

## Precondition: credentials and a site

Every call in this plugin is HTTPS to the Datadog API. Two headers, both from
environment variables or an `op://` reference, **never a literal in any file**:

```
DD-API-KEY:         $DD_API_KEY
DD-APPLICATION-KEY: $DD_APP_KEY
```

Reads need both. An API key alone authenticates submission, not query — a read
with only `DD-API-KEY` returns a `403` that reads like a permissions problem and
is in fact a missing header.

**The site is part of the hostname and getting it wrong looks like an empty
org.** A Datadog organization lives in one region, and the API host differs per
region: `api.datadoghq.com`, `api.datadoghq.eu`, `api.us3.datadoghq.com`,
`api.us5.datadoghq.com`, `api.ap1.datadoghq.com`, `api.ddog-gov.com` and others.
Querying the wrong one with valid keys returns authentication failures or empty
results, neither of which says "wrong region".

Confirm the credential and the site resolve before you read anything as
meaningful:

```bash
curl -sS -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY" \
  "https://api.<SITE>/api/v1/validate"
```

An expired key and a genuinely quiet system return results that look alike. A
responder who does not check this ends up reporting an empty result set as a
clean system — the single worst failure available in this plugin.

Throughout, `<SITE>`, `<SERVICE>`, `<ENV>`, `<MONITOR_ID>`, `<INCIDENT_UUID>` and
similar are placeholders. Substitute your own; **never paste a monitor id,
dashboard link, organization name or service name out of an example.** Those are
per-organization identifiers, they are meaningless elsewhere, and a hardcoded one
is how a skill starts silently querying somebody else's fleet.

## Read-only by default

Nothing in this plugin mutes a monitor, schedules a downtime, resolves an error
tracking issue, edits a dashboard or changes a service's configuration. Where an
action is implied, the skill names the exact call and stops.

Two mutations are in scope and both are deliberate, gated and narrow:

- **Declaring and amending an incident** — `datadog-incident-response`. Declaring
  is the core's first non-negotiable, so a plugin that could not do it would be
  useless.
- **Nothing else.**

The `dd-investigator` subagent is read-only with no exceptions at all.

## What is in here

| Component | Type | Use when |
|-----------|------|----------|
| `datadog-incident-response` | Skill | Confirming production impact, measuring blast radius from real metric queries, correlating against deploy events, and declaring and maintaining the incident record. |
| `datadog-monitors-and-queries` | Skill | You need a working query right now — metric query syntax, log search syntax, monitor types, and the aggregation and rollup semantics that decide whether a query means what you think. |
| `dd-prod-triage` | Skill | Sweeping a window of production errors into a ranked, deduplicated proposal set. Produces proposals; filing them is a tracker adapter's job. |
| `dd-investigator` | Subagent | A specific, bounded investigative question you want answered read-only, without the main session spending its context on query output. Claude Code only. |

## MCP

**This plugin ships no `.mcp.json`, deliberately.** Datadog publishes an MCP
server and it is a reasonable thing to use, but this document is not confident of
its current endpoint or of which tools it exposes, and shipping a guessed server
URL is worse than shipping none: a wrong one fails at connect time in a way that
reads like a broken plugin.

If you wire one up yourself, **declare only Datadog in it.** The whole design of
this marketplace is that installing one vendor's adapter does not drag in
another's — a combined connector file that brings a tracker, a chat platform and
a cloud along with the observability stack defeats the separation these adapters
exist to create. Every procedure in this plugin works over plain HTTPS with a
key pair, so the MCP server is a convenience, not a dependency.

## Not this plugin's job

- **Postmortems.** The `incident-postmortem` skill in the `ops-workflows` plugin
  owns the blameless write-up, the timeline format and the action-item table.
  This plugin, like the core it adapts, covers the live phase and stops at
  resolution.
- **Filing tracked work.** `dd-prod-triage` produces a proposal set and stops.
  Creating items belongs to a tracker adapter, behind the core's approval gate
  and inside the tracker's own conventions. A triage skill that files straight
  into one tracker hardcodes that tracker into an observability plugin, which is
  exactly the coupling this catalog's layering exists to prevent.
- **The judgement about when to declare, what severity means, and how to rank a
  sweep.** That is `observability-core`. If you find yourself deciding *whether*
  something is an incident from a Datadog query result, you are in the wrong
  layer — read `incident-declaration` and `blast-radius` first, then come back
  here for the numbers.
- **Instrumentation and agent configuration.** Which tags a service emits, how
  the agent is deployed, what the tracer is set to — that is the service's own
  configuration. This plugin reads what arrives and tells you honestly when a
  dimension was never instrumented.
- **Other telemetry stacks.** The procedures in the core are portable; these
  queries are not.
