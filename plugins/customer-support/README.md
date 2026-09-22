# Customer Support

Support workflows: ticket replies in your tone, escalation triage, knowledge base articles and macros.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install customer-support@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/customer-support:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
customer-support/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /customer-support:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
