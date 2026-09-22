# Software Development

Engineering workflows: architecture decision records, code review checklists, release notes and design docs.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install software-development@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/software-development:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
software-development/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /software-development:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
