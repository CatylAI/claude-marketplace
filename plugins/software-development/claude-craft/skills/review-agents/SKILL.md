---
name: review-agents
license: MIT
description: "Audit a roster of subagent definitions for correct packaging, prompt quality, and selectability. Checks whether each agent earns being a separate process or is really a skill, whether its instruction body enumerates rules where three worked examples would generalize better, and whether its description is a usable routing signal for the orchestrator that has to pick it. Returns a reclassification table, example-substitution drafts, and frontmatter rewrites. Recommendations only — it never edits. Use after adding or changing agents, when an orchestrator keeps selecting the wrong one, or as a periodic roster sweep. Not for auditing skills, hooks, or settings."
when_to_use: "audit my agents, review agent definitions, should this agent be a skill, agent description rewrite, orchestrator picks the wrong agent, agent roster sweep"
user-invocable: true
argument-hint: "[path to an agents directory; defaults to the repo's agents/ and ~/.claude/agents/]"
allowed-tools: Read, Glob, Grep, Agent
context: fork
---

# Agent Roster Audit

Evaluate every agent definition in scope across three dimensions — correct packaging, prompt
quality, and discoverability — and return recommendations. Make no edits.

Default targets when no path is given: `agents/*.md` and `plugins/*/agents/*.md` in the current
repo, plus `~/.claude/agents/*.md` if it exists.

## Background: agent or skill

**Agents** are spawned as subprocesses. Each gets its own tool grant, model, turn ceiling, and
context window. An orchestrator picks one by reading its `description`.

**Skills** are instructions loaded into whatever session is already running, using whatever tools
that session already has.

The deciding question for every file: *does this need its own isolated tool set and execution
environment, or is it Claude following a well-defined procedure?*

Signals it should be a **skill**: no meaningful `tools:` restriction; it is a checklist, a
convention, or a reference; it is always invoked mid-session with nothing running beside it and
nothing to isolate.

Signals it should stay an **agent**: a deliberate `tools:` narrowing; it runs in parallel with
siblings; an orchestrator selects it from a list; it needs a model or turn budget different from
its caller's; its output is a verdict and its working notes should not reach the caller.

## Step 1 — Read the roster

Read every agent file. Read the skills directory listing too — a conversion recommendation needs to
know whether a skill of that name already exists, and an overlap finding needs both sides.

## Step 2 — Packaging verdict

For each agent: **keep**, **convert to skill**, or **delete**.

Reason like this:

- A reviewer with `tools: Read, Grep` spawned by a pipeline as an isolated pass over prepared
  context → **keep**. Tool narrowing and a separate window each justify it on their own, even when
  nothing runs beside it.
- A file that is a list of commit-message conventions with no tool grant → **convert to skill**. It
  is a reference the model follows, not a subprocess.
- Two agents whose scopes differ (one analyses, one publishes the result) → **keep both**. Flag
  overlap only when two agents perform the *same* analysis.
- A file with no inbound reference anywhere and a scope another agent already covers →
  **delete**, naming the agent that covers it.

## Step 3 — Rules to examples

Scan each instruction body for sections that enumerate conditions: long bullet lists of "if X then
Y" rules covering edge cases. These are candidates to replace with three concrete examples.

Models generalize from concrete patterns more reliably than they apply enumerated conditions. Three
examples should differ in situation but demonstrate one consistent principle, so the model
interpolates the fourth case you did not write.

A rule block that should be replaced:

```
- If the branch starts with fix/, use fix as the type
- If the branch starts with feat/, use feat as the type
- If there is no issue key in the branch, use the component as the scope
- If the change touches only tests, use test regardless of the branch
```

The replacement:

```
Example 1 — feature branch carrying an issue key:
  Branch: feat/PROJ-123-retry-logic
  Commit: feat(PROJ-123): add queue retry with exponential backoff

Example 2 — fix branch, no key, component scope:
  Branch: fix/api-null-pointer
  Commit: fix(api): handle null pointer in the stats aggregator

Example 3 — branch says feature, diff says otherwise:
  Branch: feat/PROJ-124-dashboard, but only test files changed
  Commit: test(PROJ-124): cover dashboard edge cases
```

For every section you flag, draft the three replacement examples. A flag without drafted examples
is not actionable.

## Step 4 — Description as a routing signal

The `description` is what an orchestrator matches against at selection time. A weak description
says what the agent *is*. A strong one says *when to pick it*, *what triggers it*, and *what it
returns*.

| Weak | Strong |
| --- | --- |
| "Reviews code for security issues" | "Security-focused review of a change: injection vectors, credential handling, authorization gaps. Returns findings ranked by exploitability. Spawned by the review pipeline when the diff touches auth or input parsing." |
| "Helps debug problems" | "Read-only root-cause analysis. Tests falsifiable hypotheses against observed evidence and returns a ranked diagnosis with a suggested fix direction. Never edits code." |

Also flag:

- names too generic to distinguish from a neighbour;
- two descriptions that would both match the same request — the orchestrator will pick
  arbitrarily, so sharpen one or merge them;
- bodies long enough that the detail should move into a referenced skill, leaving the agent file to
  carry the contract and the output shape;
- a `skills:` reference to a skill that does not exist — a dangling injection is silent at load
  time and missing at run time.

## Output

### 1. Packaging

| Agent | Recommendation | Rationale |
| --- | --- | --- |

### 2. Example substitutions

For each: the file, the section heading, the current rule block quoted, and the three drafted
replacement examples.

### 3. Frontmatter rewrites

For each: the file, the current description, the proposed description, and any other field change
(name, model, turn ceiling, tool grant).

## Rules

- One sentence of rationale per finding.
- Never propose a change to a file you have not read in full.
- Make no edits. Flag judgement calls rather than deciding them.
- A healthy roster returns a short report.
