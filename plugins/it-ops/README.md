# IT Operations

IT and SRE workflows: runbooks, incident postmortems, change requests and on-call handoffs.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install it-ops@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/it-ops:runbook` | Skill | Write an operational runbook for a service or procedure, ready for the on-call engineer at 3am | both |
| `incident-postmortem` | Skill | Write blameless incident postmortems and derive action items from timelines | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**In Cowork:** this plugin's file-based skill searches your Terraform, Kubernetes and CI files, and writes the runbook to disk when it runs in Claude Code. On the web there is no checkout and no shell, so paste the data or notes into the conversation and it works from those instead.

## Layout

```
it-ops/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /it-ops:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── (no agents: everything here runs on both surfaces)
```
