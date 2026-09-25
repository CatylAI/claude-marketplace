# ops-workflows

IT and SRE workflows: on-call runbooks built from repo evidence, and blameless incident
postmortems with owned, dated action items.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install ops-workflows@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## Skills

| Skill | Use it when |
| --- | --- |
| `/ops-workflows:runbook <service>` | You need an on-call runbook for a service or procedure. Builds it from the repo's manifests, CI, scripts and alert definitions, cites the file behind every command, and marks every gap `TODO(owner)` with an Open TODOs list. |
| `/ops-workflows:incident-postmortem` | An incident is resolved and needs its blameless write-up. Takes the incident record from `observability-core:incident-declaration` (or pasted notes) and produces a timeline, a causal chain of contributing factors, what went well, and an action table where every row has an owner, a due date and a checkable "done when". |

Both skills also trigger from a plain description of what you want, so you don't need the
slash command.

## Surfaces

Both skills load in Claude Code and Cowork. The plugin ships no agents, hooks or MCP servers.

- **Claude Code in a checkout:** `runbook` searches the repository and saves to
  `docs/runbooks/<name>.md`. `incident-postmortem` can read a record from a file, returns the
  postmortem inline, and saves it to `docs/postmortems/` only if you agree.
- **Web, or no checkout:** paste the manifests, alert definitions, incident record or notes.
  Both skills work from what you paste and return the result inline; nothing is written.

## Related plugins

- `observability-core` owns the live phase: `incident-declaration` (the Sev1–Sev4 scale, the
  incident record and its states), `blast-radius` and `production-triage`. `incident-declaration`
  hands off to `ops-workflows:incident-postmortem` at close-out.
- `datadog-observability` and `gcp-observability` hand their blameless write-ups to
  `ops-workflows:incident-postmortem` too.

## Layout

```
ops-workflows/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    ├── incident-postmortem/SKILL.md
    └── runbook/SKILL.md
```

## License

MIT
