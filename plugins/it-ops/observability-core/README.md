# observability-core

Vendor-neutral incident discipline for the live phase of an incident: declare early, measure
blast radius, and triage production errors into tracked work.

The skills are written against capabilities (an error aggregator, a metrics store, a deploy
log, an incident record) rather than products, so they read the same whether your telemetry is
a hosted APM, a cloud provider's logging and metrics, a self-hosted log cluster, or rotated log
files you grep.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install observability-core@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## Skills

| Skill | Use it when |
| --- | --- |
| `incident-declaration` | Production impact is confirmed or suspected. Declare at confirmation, set severity from the measured population, name the roles, post updates on a fixed cadence with a template, call the scope-reset checkpoint after two failed mitigations, and close out with a checklist. |
| `blast-radius` | Severity needs a number behind it. Measures users, requests, tenants, scope, time and data integrity, checks what changed, and produces the reporting block whose last line names the dimension that set severity. |
| `production-triage` | Sweeping a window of production errors. Aggregates by signature, merges, ranks by impact rather than count, dedupes against the tracker, proposes items, files only what you approve, and reports every cluster's outcome. |

## Tell it where your telemetry lives

Add a `## Observability capabilities` section to your project's `CLAUDE.md`: where errors
aggregate, where metrics live, the exact production tag, the deploy and change log, known
coverage gaps, where incidents are declared, the work tracker, and the comms channel. The
template is in `skills/incident-declaration/references/capabilities.md`.

The skills read that section when it exists. When it does not, they ask for the rows they need
and carry on, and offer to write the section for you at the end. Anything nobody can answer is
reported as `NOT MEASURED` rather than as zero.

## The core idea

Declare the incident the moment production impact is confirmed, not after the root cause is
found. Severity comes from the measured affected population; triage ranks by that same
population; response posture and comms cadence follow from severity. The stack trace drives the
fix, not the response.

## Surfaces

All three skills load in Claude Code and Cowork. The plugin ships no agents, hooks or MCP
servers.

- **Claude Code** with telemetry access (a CLI, an MCP server, or API credentials in the
  environment) runs the queries itself and reads `CLAUDE.md` from the checkout.
- **Without telemetry access or a checkout** (for example in Cowork or claude.ai), the skills work from what you
  paste: grouped error exports, metric values, counts, and your capability answers. Declaration
  goes ahead without numbers, and every number is labelled with its source.

## Related plugins

- `datadog-observability` and `gcp-observability` hold the vendor-specific queries and follow
  this plugin's reporting block, ranking order and templates.
- `ops-workflows:incident-postmortem` owns the blameless write-up. `incident-declaration` hands
  off to it at close-out.

## Layout

```
observability-core/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    ├── incident-declaration/
    │   ├── SKILL.md
    │   └── references/capabilities.md   # the CLAUDE.md section template
    ├── blast-radius/SKILL.md
    └── production-triage/SKILL.md
```

## License

MIT
