---
name: project-scaffold
license: MIT
description: Bootstrap a project well and run a proof of concept that ends in a decision. Covers scaffolding an empty directory into a full local skeleton, repo onboarding (CLAUDE.md hierarchy, Claude config audit), adopting Architecture Decision Records, and a POC lifecycle — frame the question and kill criteria, validate against them, then graduate or kill. Stack-neutral and forge-neutral. Use when starting a new repo, onboarding an existing one to AI-assisted development, adopting ADRs, or running a time-boxed experiment.
when_to_use: new project, bootstrap a repo, scaffold a project, scaffold an empty directory, which scaffolding skill do I want, set up CLAUDE.md, adopt ADRs, architecture decision records, start a POC, proof of concept, kill criteria, graduate a prototype, audit .claude/settings.json
user-invocable: true
---

# Project Scaffold

Two related jobs live here: **starting a repo well**, and **running a proof of concept
that ends in a decision instead of drifting into production by accident**.

Nothing in this plugin assumes a language, a cloud, a CI system, or a git forge. Where a
choice is needed, the skill asks; it never picks one for you.

## Skills

| Skill | Use it when |
| --- | --- |
| `project-create` | The request is a vague "set this project up" and the right skill is not obvious. Routes to exactly one of the others; scaffolds nothing itself. |
| `project-new` | The directory is empty and you want the whole local skeleton: CLAUDE.md hierarchy, Makefile, pre-commit config, README, `.gitignore`, initial commit. |
| `project-init` | An existing repo with code needs a CLAUDE.md hierarchy generated from templates. |
| `adr-init` | A repo has no `docs/adr/` (or only partial coverage) and you want the decisions already baked into the code written down. |
| `project-hooks` | You want to audit a repo's own `.claude/` wiring — CLAUDE.md quality, `settings.json` hygiene, discoverable agents and skills. |
| `poc-start` | You are about to build an experiment and need the question, the kill criteria, and the time box written down first. |
| `poc-validate` | A POC exists and you want an honest read against its own stated criteria. |
| `poc-graduate` | The time box is up: promote the POC to a real project, or kill it. |

## Agents

`poc-guardian` — reviews a plan against the POC contract before implementation starts, and
returns `APPROVED`, `BLOCKED`, or `NEEDS_EVIDENCE`. Read-only.

## Which skill do I want?

Routing is usually decided by two questions.

**Is the directory empty or does it already have code?**

- Has code → `project-init` (generate CLAUDE.md files) or `project-hooks` (audit what is
  already there). Generate when the repo has nothing; audit when it has something and you
  suspect it is stale or unsafe.
- Empty, and the work is an experiment → `poc-start`.
- Empty, and the work is a real project → `project-new`, which writes the whole local
  skeleton and makes the first commit. Then `adr-init` once real decisions exist. Creating
  the remote is a separate, later step you run yourself: this plugin deliberately does not
  create remotes, set branch protection, or push; that belongs to a forge-specific plugin.

If even that much is unclear, `project-create` asks the two questions and names the route.

**Are you recording decisions or making them?**

- Recording decisions that already exist in the code → `adr-init`.
- Making a decision you are not yet sure of → `poc-start`, then let the evidence decide.

If the directory state is ambiguous, inspect it before routing:

```bash
pwd
ls -A | head -20
git rev-parse --show-toplevel 2>/dev/null
find . -maxdepth 1 -name CLAUDE.md -o -maxdepth 1 -name .poc -o -maxdepth 2 -path ./docs/adr
```

State the route you picked and the one-line reason before handing off.

## The POC lifecycle in one line

`poc-start` writes the contract → you build → `poc-validate` reads the evidence against the
contract → `poc-graduate` promotes or kills. A POC with no kill criteria is not a POC; it is
an unbudgeted project.
