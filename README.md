# CatylAI Plugins for Claude Code and Cowork

Business-workflow plugins by [CatylAI](https://catylai.com), built to work in **both**
[Claude Code](https://code.claude.com) and **Cowork** (Claude Code on the web).

Every capability in this marketplace is a **Skill**. Skills load on both surfaces, so the
same plugin behaves the same whether you are in a terminal or a browser.

## Install

### Claude Code (terminal, desktop app, VS Code)

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install hiring@catylai
```

### Cowork / web

`/plugin` is **not available** in web sessions, so there is nothing to type. Enable the
plugin for your claude.ai account and Claude Code loads it automatically as a synced
plugin the next time you start a session.

If Claude tells you `/plugin` isn't available in this environment, you are on a surface
that installs from your account rather than from the session. That is expected.

## Plugins

| Plugin | What it does |
|--------|--------------|
| `hiring` | Job descriptions, structured interview scorecards, resume screening |
| `sales` | Discovery call prep, objection handling |
| `marketing` | Campaign briefs, brand voice enforcement |
| `software-development` | Architecture decision records, code review checklists |
| `customer-support` | Ticket replies, escalation triage |
| `finance` | Budget variance analysis, budget and spend reviews |
| `it-ops` | Runbooks, blameless incident postmortems |
| `project-management` | Status reports, risk registers |

## What works where

| | Claude Code | Cowork / web |
|---|:---:|:---:|
| Skills, including the `/plugin:name` ones | yes | yes |
| Connectors (Gmail, Slack, Calendar, and the rest) | yes | yes |
| Reading and writing files in a checkout | yes | no |
| Running commands (git, python) | yes | no |
| Subagents | yes | no |

Skills are the unit that travels. What a skill can *reach* differs: in Claude Code it can
open your repository and run commands, while in Cowork it works from the conversation and
from whatever Connectors you have enabled.

Two skills lean on a local checkout and give a thinner answer without one:

- `finance`, budget variance analysis, which computes from a CSV you point it at
- `project-management`, status reports, which can read `git log` for evidence

Both still work in Cowork if you paste the data in. The rest do not care where they run.

One capability is Claude Code only: the `resume-screener` subagent in `hiring`. The
`interview-scorecard` skill in the same plugin works everywhere.

## Using them

You do not need to memorise commands. Describe what you want and the matching skill loads
itself:

```
"Draft a job description for a senior SRE, remote, reporting to me"
"Help me prep for a discovery call with Acme next Tuesday"
"Write a postmortem from these incident notes"
```

In Claude Code you can also type `/` to browse them, for example
`/hiring:job-description`.

## Updates

```
/plugin marketplace update catylai
/plugin update <plugin>@catylai
```

In Cowork, updates arrive with the synced plugin. There is nothing to run.

## Feedback

Open an issue in this repository. This repo is a published release: pull requests are
welcome as suggestions, but changes land through CatylAI's release process.
