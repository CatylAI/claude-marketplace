# Software Development

Engineering workflows: architecture decision records, code review checklists, release notes and design docs.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install software-development@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/software-development:adr` | Skill | Write an Architecture Decision Record for a technical decision, numbered and saved to docs/adr/ | both |
| `code-review-checklist` | Skill | Review a diff, PR or file against a consistent engineering checklist and report findings by severity | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**In Cowork:** this plugin's file-based skill reads the codebase for context and writes the record to `docs/adr/` when it runs in Claude Code. On the web there is no checkout and no shell, so paste the data or notes into the conversation and it works from those instead.

## Layout

```
software-development/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /software-development:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── (no agents: everything here runs on both surfaces)
```
