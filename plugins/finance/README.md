# Finance

Finance workflows: budget variance analysis, forecast reviews, expense policy checks and board-ready summaries.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install finance@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/finance:variance-analysis` | Skill | Explain budget vs actual variances from a CSV or pasted table, with drivers and recommended actions | both |
| `budget-review` | Skill | Review budgets, forecasts and spend requests with a consistent set of questions and a clear recommendation | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**In Cowork:** this plugin's file-based skill reads a CSV from your project and computes the variances when it runs in Claude Code. On the web there is no checkout and no shell, so paste the data or notes into the conversation and it works from those instead.

## Layout

```
finance/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /finance:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── (no agents: everything here runs on both surfaces)
```
