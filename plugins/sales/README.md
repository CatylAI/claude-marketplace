# Sales

Sales workflows: discovery call prep, objection handling, proposal drafting and pipeline reviews.

## Install

```
/plugin marketplace add CatylAI/catylai-marketplace
/plugin install sales@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/sales:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
sales/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /sales:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
