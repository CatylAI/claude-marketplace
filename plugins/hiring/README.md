# Hiring

Recruiting workflows: job descriptions, structured interview scorecards, resume screening and offer letters.

## Install

```
/plugin marketplace add CatylAI/catylai-marketplace
/plugin install hiring@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/hiring:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
hiring/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /hiring:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
