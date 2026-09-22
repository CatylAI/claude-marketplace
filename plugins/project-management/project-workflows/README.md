# Project Management

Project workflows: status reports, risk registers, RACI charts and sprint retrospectives.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install project-management@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/project-management:status-report` | Skill | Produce a weekly project status report from notes, tickets, or commit history | both |
| `risk-register` | Skill | Create and maintain a project risk register with likelihood, impact, owners and mitigations | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**In Cowork:** this plugin's file-based skill can read `git log` for evidence of what shipped when it runs in Claude Code. On the web there is no checkout and no shell, so paste the data or notes into the conversation and it works from those instead.

## Layout

```
project-management/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /project-management:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── (no agents: everything here runs on both surfaces)
```
