---
description: Write an Architecture Decision Record for a technical decision, numbered and saved to docs/adr/
argument-hint: <decision title>
allowed-tools: Read, Glob, Grep, Write
---

Write an Architecture Decision Record (ADR) for: $ARGUMENTS

Steps:
1. Look for existing ADRs under `docs/adr/` (or `adr/`, `docs/decisions/`). Match their numbering and format if any exist. Otherwise use the format below and number this one `0001`.
2. Read the relevant parts of the codebase so the *Context* section reflects reality, and cite files.
3. If the decision is genuinely open, present at most three options with trade-offs and ask me to choose before writing the final record.

Format:

```
# ADR-NNNN: <title>

Date: YYYY-MM-DD
Status: Proposed | Accepted | Superseded by ADR-NNNN

## Context
What forces are at play: requirements, constraints, what hurts today. Facts, not opinions.

## Decision
What we are doing, in one paragraph. Active voice: "We will…".

## Options considered
- Option A — pros / cons
- Option B — pros / cons

## Consequences
What becomes easier, what becomes harder, what we must now do (migrations, follow-ups).
```

Save it to `docs/adr/NNNN-<kebab-title>.md` and print the path.
