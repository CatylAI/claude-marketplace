---
name: config-audit
license: MIT
description: "One-shot health check of a whole Claude Code configuration. Runs the skills, agents and hooks audits together in parallel, adds a settings and permissions layering pass — precedence across the settings files, deny-ask-allow ordering, shadowed or over-broad rules — and merges everything into a single ranked report with the cross-cutting findings no single-dimension audit can see, such as a skill and an agent that should swap places or a reference skill nothing calls. Recommendations only — it never edits. Use for a periodic whole-configuration sweep or before handing a configuration to someone else. Not for a targeted fix, and not when you only need one dimension: run review-skills, review-agents or review-hooks directly."
when_to_use: "audit my whole claude config, config health check, settings precedence, permission rules review, which settings file wins, quarterly config sweep, my claude setup is a mess"
user-invocable: true
argument-hint: "[optional path; defaults to the current repo plus ~/.claude/]"
allowed-tools: Read, Glob, Grep, Agent
context: fork
---

# Whole-Configuration Audit

Runs the three dimension audits together, adds a settings layering pass, and synthesizes one
report. This is a dispatcher: it does not reimplement the dimension audits, it spawns them and
merges what they return.

## Why a dispatcher

`review-skills`, `review-agents`, and `review-hooks` all run in a forked context, which means they
cannot be loaded with the `Skill` tool. Spawn their work with the `Agent` tool instead — one message
carrying all calls so they run concurrently. `review-skills` may fan out further internally; that is
expected and does not need coordinating from here.

## Step 1 — Spawn the dimension audits

In one message, issue four `Agent` calls. Each prompt names the skill file to read and follow, the
target, and the deliverable:

- **Skills** — "Read the `review-skills` skill and execute its audit against the skills in scope.
  Return the immediate-fix list, the reclassification table, the description rewrites, and the
  merge candidates. Recommendations only; edit nothing."
- **Agents** — "Read the `review-agents` skill and execute its audit against the agents in scope.
  Return the packaging table, the example-substitution drafts, and the frontmatter rewrites.
  Recommendations only; edit nothing."
- **Hooks** — "Read the `review-hooks` skill and execute its audit against the hook scripts and
  their settings registrations. Return the ranked synthesis with file and line citations.
  Recommendations only; edit nothing."
- **Settings layering** — the pass below, which has no standalone skill.

Wait for all four before continuing.

## Step 2 — Settings and permissions layering

Configuration arrives from several files at once, and the merged result is what actually runs.
Almost nobody has read the merged result. This pass produces it.

Read every settings file in scope — the managed policy file if one is deployed, the user file, the
project file, and the local project override — and report:

1. **The effective precedence.** For each setting that appears in more than one file, state which
   file wins and whether that is what the author intended. An enterprise-managed value cannot be
   overridden locally; a local override that looks active but is not is worse than no override.
2. **Permission rule evaluation.** Deny is evaluated before ask, which is evaluated before allow.
   Find rules that can never fire because an earlier-evaluated rule already decides the case, and
   report them as dead entries rather than as working policy.
3. **Over-broad grants.** An allow entry on a whole tool where only one command shape was meant, or
   a command pattern whose wildcard admits far more than the example that motivated it. State what
   the rule actually permits, not what it was named for.
4. **Gaps under deny.** A destructive operation with no deny entry and no hook, where the only
   thing standing between the model and the operation is a written instruction.
5. **Environment and model settings.** Values set in more than one layer with different contents,
   and anything referencing a path or a machine that will not exist for another user of this repo.
6. **Secrets.** Any literal credential, token, or key in a tracked settings file. This outranks
   every other finding in this pass.

Report each with the file, the key path, and the effective merged value.

## Step 3 — Cross-cutting pass

The dimension audits each see only their own target. The findings that span them are this
dispatcher's actual contribution:

- **Swapped packaging** — a skill that should be an agent *and* an agent that should be a skill,
  each flagged from its own side. Usually they are the same pair.
- **Orphans** — a reference skill, hidden from the menu or model-disabled, with no inbound call
  anywhere: no `Skill()` invocation, no `skills:` injection, no mention in any instruction file.
  Confirm before reporting, with a grep across the skills, agents, and instruction files that
  excludes the skill's own directory.
- **Rule-to-hook gaps** — an instruction the hooks audit flagged as "should be enforced" that
  skills are also relying on as a manual step. Two dimensions independently paying for the same
  missing hook.
- **Enforcement contradicted by prose** — a permission deny for an operation that a skill or
  instruction file tells the model to perform. One of them is wrong and the model will spend turns
  discovering which.
- **Duplicated guidance** — the same standard inlined in several skills, which should be one
  reference; or one reference so general that each caller re-specialises it, which should be
  several.

## Step 4 — One report

```
# Configuration audit

## Per dimension
- Skills:   <n> findings (<immediate fixes> / <reclassifications> / <merges>)
- Agents:   <n> findings (<keep> / <convert> / <delete>)
- Hooks:    <n> findings (<critical> / <warning> / <minor>)
- Settings: <n> findings (<precedence> / <permissions> / <secrets>)

## Cross-cutting
<the Step 3 items — what no single dimension could see>

## Ranked actions
| # | Dimension | Action | File | Why |
|---|-----------|--------|------|-----|

## Needs a decision
<genuine trade-offs, with the options and their costs — not decided here>
```

One sentence of rationale per item. Cite file and line. Recommend only; make no edits. A
configuration that is already in good shape gets a short report.
