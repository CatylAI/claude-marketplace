# Project Management

Project workflows: status reports, risk registers, RACI charts and sprint retrospectives.

## Install

```
/plugin marketplace add CatylAI/catylai-marketplace
/plugin install project-management@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/project-management:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
project-management/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /project-management:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
