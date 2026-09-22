# project-scaffold

Bootstrap a project and run a proof of concept that ends in a decision.

Two jobs, one plugin:

- **Start a repo well** — scaffold an empty directory into a working local skeleton,
  generate a CLAUDE.md hierarchy, audit the repo's own `.claude/` wiring, and write down the
  architectural decisions the code already encodes as ADRs.
- **Run a POC honestly** — state the question and the kill criteria up front, check the
  evidence against them, then graduate the work or kill it.

Everything here is stack-neutral and forge-neutral. No language, cloud, CI system, agent
framework, or hosting runtime is assumed or mandated. Where a choice matters, the skill asks.

## Skills

| Skill | Purpose |
| --- | --- |
| `project-create` | Router. Inspects the directory, asks at most two questions, and names exactly one of the skills below. Writes nothing itself. |
| `project-new` | Scaffold an empty directory into a full local skeleton: CLAUDE.md hierarchy, Makefile, `.pre-commit-config.yaml`, README, `.gitignore`, and an initial commit. Local only. |
| `project-init` | Generate a customized CLAUDE.md hierarchy (root, source, infrastructure) for a repo that already has code. |
| `adr-init` | Survey a repo, extract the decisions already made, and propose a `docs/adr/` set — writing nothing until you approve. |
| `project-hooks` | Audit and repair a repo's local Claude Code configuration: CLAUDE.md quality, `.claude/settings.json` hygiene, project agents and skills. |
| `poc-start` | Write the POC contract: the question, the falsifiable success signal, the kill criteria, the time box, the chosen stack and target runtime. |
| `poc-validate` | Read-only check of a POC against its own contract. Reports met / unmet / unmeasurable per criterion. |
| `poc-graduate` | Close the POC out: promote to a real project on the target runtime chosen at start, or kill it and record why. |

## Agents

- `poc-guardian` — read-only plan reviewer. Checks a proposed plan against the POC's own
  contract (in-scope for the question, within the time box, measurable against the kill
  criteria) and returns `APPROVED`, `BLOCKED`, or `NEEDS_EVIDENCE`.

## Templates

`templates/claude-md/` ships the CLAUDE.md templates `project-init` and `project-new` fill
in: `root.md`, `src.md`, and `infra.md`. They use `${PLACEHOLDER}` tokens that the skill substitutes from
detected project facts. Edit them to match your own house style — the skill reads whatever
is in that directory.

## What this plugin does not do

- It never creates a remote repository, pushes, sets branch protection, or opens a merge
  or pull request. Forge operations belong to a forge-specific plugin — see
  `github-workflow` for pull request lifecycle and GitHub Actions authoring. `project-new`
  stops at the first local commit.
- It never dictates the POC's stack. A proof of concept exists to answer a question; the
  tools it uses are the author's choice.
- It never writes a `rules/` directory or other non-native configuration.

## Surfaces

Skills load in both Claude Code and Cowork (Claude Code on the web). **`poc-guardian` is a
subagent and is Claude Code only** — in Cowork the plan review it performs has to be done in
the main thread, which means it is no longer an independent check by a reviewer that cannot
see the plan's author reasoning.

Every skill here begins by reading repo state — `git`, existing files, `.claude/` wiring. On
the web there is no checkout and no shell, so they work from what you paste into the
conversation. `adr-init`, `project-init` and `project-new` can still draft their output
there; you write the files yourself, and `project-new` cannot make its initial commit.
`project-create` routes fine on the web, since routing needs the directory description more
than the directory itself.

## Prerequisites

- `git`, for the repo-state checks most skills begin with.
- The `dev-standards` plugin, for the `standards-first` skill the `poc-guardian` agent loads.

## Install

```
/plugin install project-scaffold@<your-marketplace>
```
