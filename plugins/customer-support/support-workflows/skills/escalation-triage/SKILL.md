---
name: escalation-triage
description: Triage support tickets by severity and decide whether to escalate, to whom, and with what information. Use when the user mentions a backlog of tickets, asks what to escalate, needs a severity or priority for an issue, or asks how to hand a customer issue to engineering.
---

# Escalation triage

Escalate on impact and blast radius, not on how loudly the customer is asking.

## Severity scale

| Sev | Definition | Response target | Route to |
|-----|------------|-----------------|----------|
| 1 | Service down or data loss for many customers, or security incident | 15 min, page on-call | Incident channel + on-call engineer |
| 2 | Major feature broken, workaround missing, several customers affected | 1 hour | Engineering lead |
| 3 | Feature degraded with a workaround, or single customer blocked | 1 business day | Product/engineering backlog with owner |
| 4 | Cosmetic, question, or feature request | 3 business days | Knowledge base or product feedback |

## Triage a ticket

1. Classify: bug, how-to, billing, feature request, security.
2. Assess impact: how many customers, revenue at risk, is there a workaround.
3. Assign severity from the table. When in doubt between two, pick the higher and say why.
4. Decide escalation. Only Sev 1 and 2 page people; Sev 3 gets a ticket with an owner.

## Escalation hand-off template

Engineering will act faster on a complete hand-off than a fast one. Include:

```
Summary:        one sentence, what is broken for whom
Severity:       S1-S4 and why
Impact:         customers affected, revenue/contract at risk
Reproduction:   exact steps, account/ID, timestamps (with timezone), environment
Expected vs actual:
Workaround:     none / describe
Customer promise: what has already been said to the customer
```

## Guardrails

- Never share customer credentials or full payment details in an escalation; reference IDs only.
- If a ticket looks like a security report, treat as Sev 1 until triaged by security, and do not discuss details in public channels.
