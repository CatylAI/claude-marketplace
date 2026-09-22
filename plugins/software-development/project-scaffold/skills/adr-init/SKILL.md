---
name: adr-init
license: MIT
description: Onboard a repository to Architecture Decision Records when it has no docs/adr/ coverage or only partial coverage. Surveys the codebase with read-only Explore agents, extracts the architectural decisions already made (module boundaries, chosen dependencies, data model, auth approach, deployment topology), proposes an ADR set for approval, then writes docs/adr/NNN-*.md plus the docs/adr/README.md index. Writes nothing before you approve. Use when adopting ADRs, when a repo has no recorded decisions, or when coverage is partial. Not for a repo that already has full coverage — add individual ADRs by hand there — and not for generating a CLAUDE.md hierarchy, which is project-init.
when_to_use: no ADRs, missing docs/adr, adopt the ADR standard, set up architecture decision records, onboard ADRs, backfill ADRs, ADR coverage, record why we chose this
user-invocable: true
disable-model-invocation: true
argument-hint: "[optional focus area, e.g. 'auth' or 'storage']"
allowed-tools: Read, Write, Bash(find:*), Bash(ls:*), Bash(git:*), Bash(mkdir:*), Bash(pwd:*), Bash(test:*), Task, AskUserQuestion
context: fork
---

# Onboard a Repo to Architecture Decision Records

An ADR records one decision that had alternatives: what was chosen, what forced the choice,
and what it costs. This skill finds the decisions a codebase has already made implicitly and
writes them down.

It is **interactive and read-first**. Nothing is written to disk until Step 3 is approved.

## Step 1 — Assess current coverage

Run these and work from the output:

```bash
pwd
git rev-parse --is-inside-work-tree 2>/dev/null || echo no
test -d docs/adr && echo yes || echo no
ls docs/adr/[0-9]*.md 2>/dev/null | wc -l | tr -d ' '
test -f docs/adr/README.md && echo yes || echo no
ls -d */ 2>/dev/null | head -20
```

In order: the current directory, whether this is a git repo, whether `docs/adr/` exists, how
many ADR files it already holds, whether there is an index, and the top-level layout. The ADR
count is what Step 4 continues numbering from, so read it rather than assuming zero.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and wait for it. Do not classify coverage or allocate ADR numbers from a guess: a proposal
that duplicates or renumbers existing ADRs is worse than no proposal.

Classify the repo from that output and say which case applies before doing anything else:

- **No `docs/adr/`** → uncovered. Full onboarding.
- **ADR files but no index** → add the index first, then backfill gaps.
- **Some ADRs** → partial. The goal is filling gaps, not duplicating. Read every existing
  ADR and the index before proposing anything, so proposals do not overlap or contradict
  what is already recorded.

If the repo is not a git repo, say so and continue anyway — ADRs are just files — but note
that the numbering convention assumes the directory is version controlled.

## Step 2 — Extract decisions with Explore agents

Launch read-only `Explore` agents via the `Task` tool. Up to three in parallel, each with a
distinct focus. If the user passed a focus area in `$ARGUMENTS`, narrow all three to it.

1. **Structure and boundaries** — module or package layout, service boundaries, the public
   API surface, how the code is decomposed and what that implies.
2. **Dependencies and data** — frameworks and notable version pins, storage engine, schema
   and data-model shape, serialization and transport formats.
3. **Runtime, auth and operations** — how and where it deploys, infrastructure-as-code
   choices, authentication and authorization approach, secrets handling, CI shape.

Ask each agent for **discrete decisions**. A decision is a choice that had a real
alternative and a tradeoff — "we use PostgreSQL rather than a document store" is a decision;
"the code has functions" is not. Each finding must carry:

- a one-line decision statement,
- the evidence (specific files or paths),
- the apparent rationale.

Tell the agents explicitly: document what **is**, do not propose changes.

## Step 3 — Propose, then wait

Consolidate the findings into a numbered candidate list. Present each as
`ADR-NNN: <title> — <one-line summary>` and use `AskUserQuestion` (multi-select) so the user
picks which to record and can edit the framing.

Do not write any file until the set is approved. If the user wants a different cut, merge or
split candidates and present again.

## Step 4 — Write the approved ADRs

Number zero-padded and sequential, continuing from any existing ADRs (`001`, `002`, …).
Never reuse or renumber. One file per decision at `docs/adr/NNN-kebab-title.md`:

```markdown
# ADR-NNN: <short decision title>

**Status:** Accepted

## Context

<the forces at play, reconstructed from the code and the user's input>

## Decision

<the decision as it stands in the code today>

## Consequences

**Good:** <what this buys>

**Tradeoff:** <what it costs, and what becomes awkward>
```

These document existing state, so `Status` is `Accepted` unless the user flags one as still
in progress (`Proposed`) or already replaced (`Superseded by ADR-NNN`).

Where a rationale is inferred rather than evidenced, say so in Context in plain words and
confirm it with the user. Never assert a reason the code cannot support — a confidently
wrong ADR is worse than a missing one.

## Step 5 — Write or update the index

`docs/adr/README.md`, one row per ADR, existing and new:

```markdown
# Architecture Decision Records

Each file records one decision: what was chosen, why, and what it costs.
Change a recorded decision and amend its ADR in the same change.

| # | Title | Status |
|---|-------|--------|
| [ADR-001](001-example-title.md) | Example title | Accepted |
```

The Status column must be honest about the present, not aspirational.

## Step 6 — Propose the repo config updates

So the repo keeps its ADRs current after this run, propose — and apply only on approval:

- **Root `CLAUDE.md`** — a short "Architecture and decisions" section naming `docs/adr/` as
  the source of truth for architectural decisions, and stating the working rule: *changing a
  decision an ADR records means amending that ADR in the same change*. If specific source
  paths map to specific ADRs, record that mapping — it is what makes the ADRs get read.
- **`.claude/settings.json`** — only if the user explicitly wants a repo-local nudge. Most
  repos do not need one; the CLAUDE.md line does the work. If they skip it, say so rather
  than silently omitting it.

If a `CLAUDE.md` already exists, ask before editing and offer overwrite / merge / skip for
the affected section.

## Step 7 — Summarize

List every file created or changed. Then state the two things that keep coverage alive:

1. Add or amend an ADR in the same change as any architectural decision.
2. Re-run this skill after a large refactor, to catch decisions made since.

## Notes

- Read first, write last. Nothing before Step 3 approval.
- Never fabricate a decision or a rationale. Mark inferences as inferences.
- Continue numbering from existing files; never renumber and never reuse a number.
- A retired decision is superseded, not deleted — the history is the point.
- After onboarding, individual ADRs are written by hand. This skill is for the initial sweep.
