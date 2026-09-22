# observability-core

Vendor-neutral incident discipline: declare early, establish blast radius, triage
production errors, and hand off cleanly to the postmortem.

Everything here is written against **capabilities** rather than products. There is no
requirement for any particular observability vendor — the procedures read the same
whether your telemetry lives in a hosted APM, a cloud provider's metrics and logs
service, a self-hosted log cluster, or a directory of rotated log files you grep.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install observability-core@catylai
```

## What's inside

| Skill | Purpose |
|-------|---------|
| `incident-declaration` | The declare-at-confirmation mandate, severity by customer impact, incident roles, communication cadence, and the scope-reset checkpoint after two failed mitigations. |
| `blast-radius` | Measuring how many users, requests, tenants and regions are affected — and why that number, not the stack trace, sets severity. |
| `production-triage` | The triage loop: aggregate by error signature, merge and dedupe, rank by blast radius and novelty, propose tracked work items behind an approval gate. |

The root `SKILL.md` is the entry point and carries the capability-mapping table to fill
in once per environment.

## The core idea

**Declare the incident the moment production impact is confirmed — not after the root
cause is found.** Everything else in this plugin follows from that. Severity comes from
the measured affected population; triage ranks by that same population; the response
posture and comms cadence follow from severity. The stack trace drives the fix, never the
response.

## Relationship to `ops-workflows`

This plugin covers the **live phase** of an incident: detection, declaration, severity,
blast radius, triage, and the handoff at resolution.

It does **not** write postmortems. The `incident-postmortem` skill in the `ops-workflows`
plugin already owns the blameless write-up — timeline format, five-whys root cause,
contributing factors, what-went-well / where-we-got-lucky, and the action-item table.
`incident-declaration` ends by handing off to it rather than duplicating it. Use both:
`observability-core` while the incident is open, `ops-workflows` once it is resolved.

## Vendor adapters

Concrete queries, dashboards and incident-tool API calls belong in a separate adapter
plugin layered on top of this one. Keeping them out is what lets these procedures survive
a change of telemetry vendor.

## Prerequisites

None technical. Before first use in a new environment, fill in the capability table in
`SKILL.md`: where errors aggregate, where metrics live, where the deploy log is, where an
incident is declared, where follow-ups get owners, and where responders talk.

## Dependencies

- `dev-standards` — shared engineering conventions.

## License

MIT
