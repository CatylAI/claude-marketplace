---
name: observability-core
description: "Vendor-neutral incident and production-triage discipline. Use when production breaks, when errors need sweeping and turning into tracked work, when severity or blast radius must be decided, or when someone asks whether to declare an incident. Works with any telemetry stack — a hosted APM, a cloud-native metrics service, an ELK cluster, or grep over log files."
license: MIT
---

# Observability Core

The parts of incident response that do not depend on which telemetry product you bought.
Every procedure here is written against **capabilities** — an error aggregator, a metrics
store, a deploy log, an incident record — not against one vendor's API. Swap in whatever
your organization actually runs.

## The three non-negotiables

1. **Declare at confirmation, not at diagnosis.** The moment production impact is
   confirmed, open the incident record. Do not investigate quietly first.
   → `skills/incident-declaration/`
2. **Impact sets severity, not the stack trace.** Count affected users, requests,
   tenants and regions before choosing a response posture.
   → `skills/blast-radius/`
3. **Triage aggregates before it reads.** Group errors by signature, rank by blast
   radius and novelty, and only then decide what becomes a tracked work item.
   → `skills/production-triage/`

## Skills in this plugin

| Skill | Use when |
|-------|----------|
| `incident-declaration` | Production impact is confirmed or suspected; severity, roles and comms cadence need setting. |
| `blast-radius` | You need the affected-population number that drives severity and response. |
| `production-triage` | Sweeping a window of production errors and converting the real ones into tracked work. |

## What this plugin deliberately does not do

- **Postmortems.** The `incident-postmortem` skill in the `ops-workflows` plugin owns
  the blameless write-up, timeline format and action-item table. This plugin covers the
  *live* phase — declaration through triage — and hands off to that skill at resolution.
- **Vendor integrations.** No queries, dashboards, monitor IDs or credentials for any
  specific observability product. A vendor adapter plugin can layer concrete queries on
  top of these procedures; this layer stays portable.

## Required capabilities (map these once, per environment)

Before using these skills in a new environment, write down the local answer to each:

| Capability | The local answer |
|------------|------------------|
| Error aggregator | Where errors can be grouped and counted by signature |
| Metrics store | Where request rate, error rate and latency percentiles live |
| Deploy/change log | What shipped in the last 24h, across every repo that touches the path |
| Incident record | Where an incident is declared and its timeline kept |
| Work tracker | Where follow-ups become owned, scheduled items |
| Comms channel | Where responders coordinate and stakeholders are updated |

If a capability has no local answer, say so out loud during the incident. An unmeasured
dimension is an unknown, not a zero.
