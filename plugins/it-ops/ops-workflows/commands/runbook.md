---
description: Write an operational runbook for a service or procedure, ready for the on-call engineer at 3am
argument-hint: <service or procedure name>
allowed-tools: Read, Glob, Grep, Write
---

Write a runbook for: $ARGUMENTS

First, search the project for anything relevant: Terraform or Kubernetes manifests, Dockerfiles, CI configs, existing docs, alert definitions. Base the runbook on what you find and cite the files. Where something is unknown, leave a clearly marked `TODO(owner)` rather than guessing.

Runbook format:

```
# Runbook: <name>

Owner: <team>        Last reviewed: YYYY-MM-DD        Escalation: <who / how>

## What this is
One paragraph: what the service does, who depends on it, what "healthy" looks like.

## Dashboards and logs
Links or commands to the first three things to look at.

## Common alerts
For each alert: meaning, first checks (commands), likely causes, fix, and how to verify the fix.

## Procedures
Step-by-step for: restart, scale, roll back, rotate credentials, fail over. Every step is a copy-pasteable command with its expected output.

## Known failure modes
Table: symptom, cause, fix, ticket/link.

## Do not
Actions that look tempting and make it worse.
```

Save to `docs/runbooks/<kebab-name>.md` and print the path.
