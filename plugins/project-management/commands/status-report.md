---
description: Produce a weekly project status report from notes, tickets, or commit history
argument-hint: <project name> [week or date range] [path to notes]
allowed-tools: Read, Glob, Grep, Bash(git log:*), Bash(git shortlog:*)
---

Write a status report for: $ARGUMENTS

Gather evidence first: notes or files I point you to, and if this is a code project, `git log` for the period. Cite where each claim came from. If you find nothing, ask me for bullet points rather than inventing progress.

Format (fits on one screen):

```
# <Project> — status for <period>

Overall: 🟢 On track | 🟡 At risk | 🔴 Off track — one sentence why.

## Done this period
- ... (outcome, not activity)

## Planned next period
- ...

## Risks and blockers
| Risk/blocker | Impact | Owner | Ask |

## Decisions needed
- <decision>, by <date>, from <person>

## Key dates
- Milestone — date — status
```

Rules: no more than five bullets per section, every risk has an owner and an ask, and the overall colour must be justified by the content below it.
