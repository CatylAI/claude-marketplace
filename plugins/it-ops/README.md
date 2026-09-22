# IT Operations

IT and SRE workflows: runbooks, incident postmortems, change requests and on-call handoffs.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install it-ops@catylai
```

## What's inside

| Type | Name | Purpose |
|------|------|---------|
| Command | `/it-ops:...` | See `commands/` |
| Skill | see `skills/` | Loaded automatically when the conversation matches its description |

## Layout

```
it-ops/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # slash commands: /it-ops:<file-name>
├── skills/<skill>/SKILL.md      # auto-triggered knowledge and workflows
└── agents/                      # subagents Claude can delegate to
```
