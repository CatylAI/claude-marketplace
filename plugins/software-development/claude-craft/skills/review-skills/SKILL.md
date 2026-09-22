---
name: review-skills
license: MIT
description: "Audit a tree of SKILL.md definitions for authoring quality and correct classification. Checks four dimensions: whether each skill should be a skill at all rather than a subagent, whether a forked context is justified or wasteful, whether the invocability flags match how the skill is actually reached, and whether the description is specific enough to trigger. Returns an immediate-fix list, a reclassification table, description rewrites, and merge candidates. Recommendations only — it never edits. Use after adding or changing skills, before publishing a plugin, or as a periodic sweep of a skills directory. Not for auditing agent definitions, hook wiring, or settings layering."
when_to_use: "audit my skills, review SKILL.md quality, why does my skill never trigger, should this be an agent, skill description rewrite, skills directory sweep, prune duplicate skills"
user-invocable: true
argument-hint: "[path to a skills directory; defaults to the repo's skills/ and ~/.claude/skills/]"
allowed-tools: Read, Glob, Grep, Agent
context: fork
---

# Skill Authoring Audit

Read every `SKILL.md` under the target tree and produce actionable recommendations across four
dimensions: classification, context mode, invocability, and description quality. Recommend only —
make no edits.

Default targets when no path is given: `skills/*/SKILL.md` and `plugins/*/skills/*/SKILL.md` in the
current repo, plus `~/.claude/skills/*/SKILL.md` if it exists.

## Background: what a skill is, and what it is not

A **skill** is instructions loaded into a session. Claude follows them with the tools it already
has. Two modes:

- **Inline** (the default, no `context:` field) — the body is injected into the current
  conversation. Right for checklists, reference material, conventions, and short procedures the
  model performs in place.
- **`context: fork`** — the skill runs in an isolated subagent with its own window. Right when the
  work is long enough to crowd the caller's context, needs a different tool set, or benefits from a
  clean slate. A forked skill is reached by slash command or the `Agent` tool; it cannot be invoked
  with the `Skill` tool. That constraint is the single most common authoring mistake — a reference
  skill marked `fork` becomes unreachable from the places that meant to load it.

An **agent** (`agents/*.md`) is a separate process with its own tool grant, model, and turn limit,
selected by an orchestrator reading its `description`. A skill should become an agent when it is
spawned in parallel with siblings, needs a `maxTurns` or `model` different from its caller, or is
picked from a candidate list at run time.

Invocability flags:

| Frontmatter | Effect |
| --- | --- |
| `user-invocable: true` | Appears in the slash menu; the model may also auto-select it. |
| `user-invocable: false` | Hidden from the menu; still auto-selectable. |
| `disable-model-invocation: true` | Only the user can invoke it. Correct for side-effecting workflows. |

A reference skill that exists to be pulled in by another skill or agent should not also be sitting
in the slash menu advertising itself as a workflow.

## Step 1 — Inventory

Read every `SKILL.md` in scope. Read the repo's authoring conventions too if it has any
(`CLAUDE.md`, a plugin standard). List the agent definitions that exist alongside the skills — you
cannot judge "this should be an agent" or "this duplicates an agent" without knowing the roster.

Group the skills yourself by observed prefix or theme. Do not assume a fixed taxonomy; derive it
from the names actually present, and say what grouping you used.

## Step 2 — Fan out

If there are more than roughly a dozen skills, split the groups across parallel subagents (three to
four is usually right) so no single agent reads more than it can hold. Give each agent one group and
the rubric below verbatim. With fewer skills, do the pass yourself.

Each skill is evaluated on six questions:

1. **Type** — keep as a skill, convert to an agent, or delete. Delete means: an exact duplicate, a
   skill superseded by another, or one nothing references and nobody invokes.
2. **Context mode** — if `context: fork`, is the isolation earned? A reference document or a
   ten-line checklist should be inline. If inline, does it do enough long, noisy work that it
   should be forked?
3. **Invocability** — do `user-invocable` and `disable-model-invocation` match how the skill is
   actually reached? A workflow with side effects (writes, commits, deploys) should be
   user-invoked only. A pure reference should not be in the slash menu.
4. **Description quality**, against this rubric:
   - *Bad*: says what the skill **is** ("Helps with testing"), no triggers, no boundaries.
   - *Good*: says what it does **and when to reach for it**, in the user's vocabulary, with an
     explicit "not for X" boundary against neighbouring skills.
   - Flag descriptions that are empty, truncated, or a dangling YAML block scalar — these silently
     break discovery and are the highest-priority fix.
   - Flag descriptions so long the model must scan past the trigger to find it; put the use case
     first.
   - Flag descriptions with no trigger phrasing at all.
5. **Merge candidates** — two skills whose descriptions would both match the same request. Either
   merge them or sharpen the boundary in both descriptions.
6. **Gaps** — a theme where one obvious member is missing, or where two skills both assume a third
   that does not exist.

Have each agent return structured findings:

```json
[
  {
    "skill": "skill-name",
    "type_verdict": "keep | convert-to-agent | delete",
    "context_verdict": "justified | should-be-inline | should-be-fork | n-a",
    "invocability_verdict": "correct | needs-change",
    "description_quality": "good | needs-rewrite | truncated | missing",
    "proposed_description": "only when needs-rewrite or truncated",
    "notes": "one sentence"
  }
]
```

## Step 3 — Synthesize one report

### 1. Immediate fixes

Every skill whose description is missing or truncated. These block discovery entirely.

| Skill | Problem | Proposed description |
| --- | --- | --- |

### 2. Reclassification

| Skill | Verdict | Rationale (one sentence) |
| --- | --- | --- |

### 3. Description rewrites

For each: the skill name, the current description quoted, and the proposed replacement. The rewrite
must name the trigger case first and carry at least one anti-trigger.

### 4. Merge candidates

| Skill A | Skill B | Overlap | Recommendation |
| --- | --- | --- | --- |

### 5. Ranked actions

The ten highest-value changes, most valuable first. Each cites the file path and states the concrete
edit.

## Rules

- One sentence of rationale per finding. Volume is not thoroughness.
- Cite the file path for everything.
- Make no edits. Flag anything that needs a judgement call rather than deciding it.
- A tree that is already in good shape returns a short, clean report. Do not manufacture findings.
