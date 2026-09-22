# Hiring

Recruiting workflows: job descriptions, structured interview scorecards, resume screening and offer letters.

Works in **Claude Code** and in **Cowork** (Claude Code on the web).

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install hiring@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `/hiring:job-description` | Skill | Draft a job description from a role title and a few bullet points about the team | both |
| `interview-scorecard` | Skill | Build and fill in structured interview scorecards | both |
| `resume-screener` | Subagent | Screens a batch of resumes against a job description and returns a ranked shortlist with evidence | Claude Code only |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**Subagents are Claude Code only.** `resume-screener` is unavailable in Cowork; the skills above are not.

## Layout

```
hiring/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── commands/                    # skills you can invoke as /hiring:<file-name>
├── skills/<skill>/SKILL.md      # skills that trigger from the conversation
└── agents/                      # subagents; Claude Code only
```
