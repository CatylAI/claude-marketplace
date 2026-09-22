---
name: project-hooks
license: MIT
description: Audit and repair a repository's own Claude Code configuration — the CLAUDE.md files, the local .claude/settings.json hook wiring and permission rules, and the discoverability of project agents and skills. Reports what is present, missing, or misconfigured, then fixes what you approve. Use when starting work in an unfamiliar repo, when a repo's hooks misbehave, or when checking that a repo is not quietly weakening safety settings. Not for generating a full CLAUDE.md hierarchy from templates, which is project-init, and not for auditing a user's global configuration.
when_to_use: audit .claude/settings.json, check project hooks, is this repo set up for Claude, repo Claude config, hooks not firing, bypassPermissions, project agents not discovered
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git:*), Bash(find:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), AskUserQuestion
context: fork
---

# Audit a Repo's Claude Code Configuration

Scope is the **repository**: its `CLAUDE.md` files and its `.claude/` directory. A user's
personal global configuration is out of scope and must not be modified from here.

## Step 1 — Establish state

Run these and work from the output:

```bash
git rev-parse --show-toplevel 2>/dev/null || echo "(not a git repo)"
ls CLAUDE.md .claude/CLAUDE.md 2>/dev/null || echo "(missing)"
ls .claude/settings.json .claude/settings.local.json 2>/dev/null || echo "(none)"
ls .claude/agents/*.md 2>/dev/null | head -10 || echo "(none)"
ls .claude/skills/*/SKILL.md 2>/dev/null | head -10 || echo "(none)"
ls .claude/hooks/* 2>/dev/null | head -10 || echo "(none)"
ls package.json pyproject.toml go.mod Cargo.toml Makefile 2>/dev/null | head -10
git ls-files .claude/ 2>/dev/null | head -10 || echo "(none tracked)"
```

In order: the repo root, the CLAUDE.md files, the settings files, project agents, project
skills, hook scripts, stack signals, and which of `.claude/` is tracked by git.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and wait for it. Do not report on configuration you have not read; a clean audit of an unread
repo is the worst outcome this skill can produce.

Then determine the repo root and classify each component as **present**, **missing**, or
**misconfigured**:

| Component | Path | Why it matters |
| --- | --- | --- |
| Project memory | `CLAUDE.md` or `.claude/CLAUDE.md` | Without it, every session rediscovers the project's commands and constraints |
| Shared settings | `.claude/settings.json` | Team-wide hooks and permissions; belongs in version control |
| Local settings | `.claude/settings.local.json` | Per-developer overrides; must be gitignored |
| Project agents | `.claude/agents/*.md` | Optional, but only discovered from this path |
| Project skills | `.claude/skills/*/SKILL.md` | Optional; each needs its own directory with a `SKILL.md` |
| Hook scripts | `.claude/hooks/` | Referenced by settings; a missing script is a silently dead hook |

If this is not a git repo, say so and continue — the checks still apply — but note that
shared settings only reach teammates through version control.

## Step 2 — Review the CLAUDE.md

Read it. Judge it on whether it would actually change what a session does:

- Are the build, test, and lint commands stated, and do they match what the repo really
  uses? Cross-check against the manifest or task runner. A wrong command here gets run.
- Does it state constraints specific to this repo, rather than generic advice that applies
  to every project?
- Are there dead references — paths that no longer exist, renamed commands, a tool the repo
  has since dropped?
- Is it short enough to be read to the end?

Report concretely: quote the stale line, name the file it points at, say what it should be.

## Step 3 — Review the settings

Parse each settings file and stop on invalid JSON — a settings file that does not parse is
silently ignored, and that failure mode looks identical to "no settings at all".

```bash
jq empty .claude/settings.json && echo "valid JSON"
```

Check, in priority order:

1. **`permissions.defaultMode`** — a repo-local setting of `bypassPermissions` or an
   equivalently permissive mode is the highest-severity finding in this audit. It disables
   the prompts and hooks that stand between a session and the filesystem, for everyone who
   clones the repo. Report it first; never add one; never leave one in place silently.
2. **Hook wiring** — for every `command` referenced under `hooks`, confirm the script
   exists and is executable. Use `${CLAUDE_PLUGIN_ROOT}` or a repo-relative path, never an
   absolute path containing a home directory — an absolute personal path is broken for
   every other developer.
3. **Duplicate hooks** — a hook already supplied by a plugin or by the user's global
   settings, repeated here, fires twice per tool call. Flag repeats rather than assuming
   the repo meant it.
4. **`permissions.deny`** — check that genuinely destructive operations for this stack are
   denied. Derive the list from the stack: infrastructure teardown for an
   infrastructure-as-code repo, force-push and history rewriting for any repo, database
   drops for a service that owns a datastore. Do not paste a generic list.
5. **Local settings hygiene** — `.claude/settings.local.json` must be gitignored. If it is
   tracked, that is a finding: personal overrides, and sometimes machine paths or tokens,
   are reaching the shared repo.
6. **Secrets** — no tokens, keys, or credentials in any settings file. Report a finding
   without reproducing the value.

## Step 4 — Check agents and skills discoverability

- Each project agent is a single `.md` file directly in `.claude/agents/` with frontmatter
  carrying at least `name` and `description`. A file nested a directory deeper is not found.
- Each project skill is `.claude/skills/<name>/SKILL.md`. A bare `.md` file in
  `.claude/skills/` is not a skill and will not load.
- Any skill or agent referenced by a hook, a CLAUDE.md, or another skill must actually
  exist. Report a dangling reference — it fails at the moment of use, which is the worst
  moment to discover it.

## Step 5 — Present findings and ask

Report findings in severity order — permissive mode first, then broken wiring, then stale
content, then optional gaps — each with the file, the specific line or key, and the fix.

Then ask with `AskUserQuestion`:

- **Report only** — show the audit, change nothing.
- **Fix the safety findings** — permissive mode, broken hook paths, tracked local settings.
- **Fix everything interactively** — walk each finding, one approval each.
- **Create the missing CLAUDE.md** — if there is none. Note that a full multi-level
  hierarchy is `project-init`'s job; this skill writes a single root file.

## Step 6 — Apply approved fixes

Edit surgically: change the key at issue, preserve everything else, keep the file's existing
formatting. Re-validate the JSON after every settings edit.

If the missing CLAUDE.md is being created, write a single root file with what was actually
detected — the real commands, the real layout, the repo's real constraints. Show it to the
user before saving and ask what to add or remove.

## Step 7 — Summarize

```
Repo Claude configuration
  CLAUDE.md             present / created / missing
  .claude/settings.json valid / fixed / invalid / absent
  local settings        gitignored / TRACKED (finding)
  hook wiring           N hooks, M broken
  project agents        N discovered
  project skills        N discovered

Actions taken:
Remaining gaps:
```

## Notes

- Absent settings are not a finding. A repo with no `.claude/settings.json` is inheriting
  the user's own configuration, which is usually correct. Only recommend creating one when
  the repo genuinely needs a shared, version-controlled override.
- Never duplicate a hook that a plugin or the user's global configuration already provides.
- Never widen permissions to make something work. Narrowing them is a fix; widening them is
  a decision the user makes, not this skill.
- The highest-value thing a repo can have is an accurate CLAUDE.md. Spend the effort there.
