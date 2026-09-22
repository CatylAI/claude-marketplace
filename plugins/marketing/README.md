# Marketing

Marketing workflows: campaign briefs, brand voice enforcement, content calendars and launch plans.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install marketing@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/marketing:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
marketing/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /marketing:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
