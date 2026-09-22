# Finance

Finance workflows: budget variance analysis, forecast reviews, expense policy checks and board-ready summaries.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install finance@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/finance:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
finance/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /finance:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
