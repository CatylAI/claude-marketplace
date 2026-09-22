# Customer Support

Support workflows: ticket replies in your tone, escalation triage, knowledge base articles and macros.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install customer-support@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/customer-support:ticket-reply` | Skill | Draft a reply to a support ticket in a calm, clear, customer-first tone | both |
| `escalation-triage` | Skill | Triage support tickets by severity and decide whether to escalate, to whom, and with what information | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

## Layout

```
customer-support/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /customer-support:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── (no agents: everything here runs on both surfaces)
```
