---
name: claude-config-audit
license: MIT
description: "Audit one repository's Claude Code configuration end to end and fix what you approve. Maps the CLAUDE.md hierarchy, skills, settings and hooks, then flags mechanism errors: a repeatable procedure buried in CLAUDE.md prose that should be a skill, a must-hold policy left as a written instruction that should be a permission deny or a hook, an unscoped instruction burning tokens on every turn, a nested CLAUDE.md contradicting its parent, a skill whose description is too vague to ever trigger. Proposes fixes, writes nothing until you approve, then applies them. Use when adopting a configuration standard, onboarding a repo, or before shipping configuration changes. Not for a whole-machine sweep of a skills, agents and hooks roster — that is config-audit."
when_to_use: "audit claude config, review CLAUDE.md placement, is this a rule or a skill, should this be a hook, my CLAUDE.md is too long, unscoped instruction, onboard a repo to a claude config standard"
user-invocable: true
disable-model-invocation: true
argument-hint: "[optional path to a repo or .claude directory; defaults to the current directory]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find:*), Bash(ls:*), Bash(git:*), Bash(echo:*), Bash(test:*), Agent, AskUserQuestion
context: fork
---

# Audit a Repository's Claude Code Configuration

Bring one repository's configuration into a defensible shape. This is an **interactive** audit: it
maps what exists, flags mechanism and scope errors, proposes fixes, and writes only after approval.
It never silently rewrites configuration.

The subject is *placement and enforcement strength* — is this instruction expressed through the
right mechanism, scoped to the right files, and binding as hard as it needs to bind.

## The standard being audited against

Four mechanisms, in increasing order of how hard they bind:

| Mechanism | Binds | Right for |
| --- | --- | --- |
| `CLAUDE.md` | By being read | Facts about the project, conventions, orientation |
| `SKILL.md` | When selected | A repeatable multi-step procedure |
| `settings.json` permissions | Every matching tool call | Allow, ask, or deny on a tool or command shape |
| Hooks | Every matching event | A condition that must be checked, or an action that must happen |

Three rules follow from the table:

1. **A procedure is a skill, not prose.** If it has steps, an order, and a finish condition, it
   belongs in a `SKILL.md` where it is loaded on demand — not in a `CLAUDE.md` where it is paid for
   on every turn and followed approximately.
2. **A must-hold policy is code, not text.** Anything phrased "never", "always", or "before X you
   must Y" is a candidate for a permission entry or a hook. Written instructions hold *usually*.
   If usually is not good enough, the instruction is in the wrong place.
3. **Scope is a cost.** Content in a root `CLAUDE.md` enters context on every turn regardless of
   what is being edited. Content that only applies to one file type belongs behind a narrower
   surface — a nested `CLAUDE.md` in the directory it governs, or a skill the model loads when the
   work calls for it.

## Step 1 — Map the surface

The target is the path passed as an argument if there is one, otherwise the current
directory. Run these against it and work from the output — if your shell does not bind `$1`,
substitute the resolved target path for `${1:-.}` before running them:

```bash
echo "${1:-$(pwd)}"
git rev-parse --is-inside-work-tree 2>/dev/null || echo "no"
find "${1:-.}" -name CLAUDE.md -not -path '*/node_modules/*' 2>/dev/null | head -20
test -d "${1:-.}/.claude" && echo yes || echo no
find "${1:-.}" -name SKILL.md -not -path '*/node_modules/*' 2>/dev/null | head -20
find "${1:-.}" -name 'settings*.json' -not -path '*/node_modules/*' 2>/dev/null | head
find "${1:-.}" -name 'hooks.json' -not -path '*/node_modules/*' 2>/dev/null | head
```

In order: the resolved target, whether it is a git repository, its CLAUDE.md files, whether
it has a `.claude/`, its skills, its settings files, and its hook wiring. Step 2's subagents
are pointed at exactly these files, and the "nothing exists" branch below is decided by this
output.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and wait for it. Do not audit from an assumed layout: findings about files you never read are
confidently wrong, and this skill's whole output is findings.

Report what exists across all four mechanisms: the `CLAUDE.md` hierarchy (user, project root,
nested), every `SKILL.md` with its `context` and invocation flags, every permission entry, and every
hook registration.

If none of it exists, this is not an audit — it is a first-time setup. Say so, and offer to
scaffold the minimum: a project `CLAUDE.md` and one skill for the repo's most repeated procedure.

## Step 2 — Survey in parallel

Launch read-only exploration subagents (up to three) over the mapped files. Narrow to the given
path if one was passed. Split by question:

1. **Hierarchy and duplication** — does a nested `CLAUDE.md` contradict or restate its parent? Is
   machine-specific content sitting in a shared file, or shared content in a local one? Is the same
   instruction present in three places, which means two of them will eventually drift?
2. **Placement** — is a multi-step procedure written as prose that should be a skill? Is an action
   modelled as passive description? Is a skill description specific enough to be selected — would a
   user's natural phrasing match it?
3. **Enforcement strength and scope** — is a must-hold policy (destructive commands, credential
   handling, a required pre-step) left as prose instead of a deny entry or a hook? Is an
   instruction unscoped when it governs one file type? Is a permission rule so broad it grants more
   than intended, or shadowed by an earlier entry that already decides the case?

Instruct each agent to return **discrete findings only**: the problem, the file and line, the rule
from the table above that it violates, and the recommended mechanism. No fixes yet.

## Step 3 — Present for approval

Consolidate into a numbered list, most consequential first:

```
FINDING-N: <file> — <problem> → move to <mechanism>
```

Group by class, in this order:

- **Enforcement gaps** — prose that should be a deny entry or a hook. Highest priority: these are
  the standards that currently only usually hold.
- **Placement** — procedure in prose, action as description, a skill that cannot be selected.
- **Scope** — unscoped instructions paying rent on every turn.
- **Hierarchy** — contradictions and duplication.

Use `AskUserQuestion` with multi-select so the user chooses which to apply. Write nothing before
this step returns.

## Step 4 — Apply the approved fixes

Make the minimal edit for each:

- **Prose to enforcement** — write the permission entry, or the hook: name the event, the matcher,
  the detection, the exit behaviour, and the message. Wire it where the repo already keeps its
  hooks; if hooks belong to a plugin the repo installs, say so and stop rather than creating a
  parallel hook surface.
- **Prose to skill** — scaffold the `SKILL.md` with frontmatter matching the repo's conventions,
  move the procedure into it, and leave a one-line pointer where the prose was.
- **Unscoped instruction** — move it to a nested `CLAUDE.md` in the directory it governs, or into
  the skill that covers that work. Deleting the duplicate is part of the fix.
- **Contradiction** — amend or remove the losing statement. Never resolve a contradiction by adding
  a third statement; narrower scope does not reliably beat broader scope.

If the repo has a version-bump or review procedure for configuration changes, follow it for every
file you touch.

## Step 5 — Summary

List every file created or changed, and every finding deferred. Close with the operative point: an
instruction that must hold every time belongs in permissions or a hook, not in `CLAUDE.md`.

## Rules

- Read first, write last. Nothing is written before Step 3 approval.
- Do not restate the repo's frontmatter schema — reference it. One source of truth.
- A repository whose configuration is already correct gets a clean report. Do not manufacture
  findings to look thorough.
