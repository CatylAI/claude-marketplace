---
name: incident-postmortem
description: Write blameless incident postmortems and derive action items from timelines. Use when the user mentions an incident, outage, postmortem, RCA, root cause, or pastes an incident timeline or chat log.
---

# Incident postmortem

Blameless means the write-up explains how a reasonable person made each decision with the information they had. Name systems and gaps, never individuals as causes.

## Inputs to gather

- Timeline sources: alert timestamps, chat logs, deploy history, ticket updates. Ask for anything missing.
- Impact: duration, users or customers affected, error rates, revenue or SLA impact.
- The change that preceded the incident, if any.

## Postmortem format

```
# Incident YYYY-MM-DD: <short title>

Severity: S1-S4     Duration: <detect → mitigate → resolve>     Owner: <team>

## Summary
Three sentences: what broke, impact, how it was fixed.

## Timeline (UTC)
| Time | Event | Source |
Detection, diagnosis, mitigation, resolution. Include what people believed at each step.

## Root cause
The chain of conditions, not a single "human error". Use "5 whys" until you hit a system or process gap.

## Contributing factors
Alerting gaps, missing runbooks, unclear ownership, risky deploy windows.

## What went well
## What went badly
## Where we got lucky

## Action items
| Action | Type (prevent / detect / mitigate) | Owner | Due | Ticket |
Each action must be specific enough that someone could close it. "Improve monitoring" is not an action.
```

## Rules

- Timestamps in UTC with the original timezone noted once.
- Detection time is when a human or automation first noticed, not when the alert fired if nobody saw it.
- Every "should have" in the narrative becomes an action item or gets deleted.
- Keep the whole document under two pages; put raw logs in an appendix or link.
