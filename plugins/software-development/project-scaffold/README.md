# project-scaffold

Start a new project well, record the decisions a codebase already makes, and run a proof of
concept that ends in a decision.

## Skills

| Skill | Purpose |
| --- | --- |
| `project-new` | Scaffold an empty directory into a runnable local project: manifest, Makefile, pre-commit, lean CLAUDE.md, README, `.gitignore`, first commit. Local only; Claude Code only. |
| `adr-init` | Survey a repo, extract the decisions it already embodies, and write `docs/adr/` plus its index after you approve the list. Run it as `/project-scaffold:adr-init`. |
| `poc-start` | Write the POC contract (question, success signal, kill criteria, time box, target runtime) to `.poc/poc.json`, then scaffold the minimum. |
| `poc-validate` | Read-only check of a POC against its own contract: MET / NOT MET / UNMEASURED per criterion, drift, and a GRADUATE / KILL / EXTEND recommendation. |
| `poc-graduate` | Close the POC: apply `poc-validate`'s checks as a gate, then write a production plan or a kill record, and mark the contract closed. |

For a repository that already has code, use the built-in `/init` to generate CLAUDE.md and
`claude-craft:config-audit` to audit its Claude Code configuration.

## Agent

`adr-currency-validator` is a read-only completion gate. It checks that a change which alters
an architectural decision added or amended the matching `docs/adr/` file and index row, in
the format `adr-init` writes, and returns `VERDICT: PASS`, `DRIFT`, `SKIP` or `NO_VERDICT`.
Claude Code only (subagent); on the web, check ADR currency by hand before review.

## Toolchain defaults

`project-new` scaffolds Python with `uv` and TypeScript with `npm`, and Terraform with one
Makefile target per environment. Those are the only managers it writes; for another, scaffold
by hand or adapt the result. Pre-commit comes from `dev-standards:precommit-standards` and its
baseline config.

## Templates

`templates/claude-md/` holds what `project-new` fills in:

- `root.md` — a short root `CLAUDE.md`: commands, the `verify` contract, a Gotchas section.
- `infra.md` — written to `.claude/rules/infrastructure.md` with `paths:` frontmatter, so it
  loads only when Claude works on infrastructure files.

Edit them to match your house style; `project-new` reads whatever is there. Personal notes
belong in a gitignored `CLAUDE.local.md`, which `project-new` adds to `.gitignore`.

## Surfaces

The skills load in Claude Code and Cowork (web). `project-new` needs a shell and is Claude Code
only; on the web it drafts the files for you to create. `adr-init` and the POC skills work from
pasted content on the web and hand back file contents to save. `adr-currency-validator` is a
subagent and runs in Claude Code only.

## What this plugin does not do

It never creates a remote, pushes, sets branch protection, or opens a pull or merge request;
that belongs to `github-workflow` or `gitlab-workflow`. It never dictates a POC's stack.

## Prerequisites

- `git` and `make` for `project-new`, plus `uv` (Python), `npm` (TypeScript) or `terraform`
  (Terraform); `pre-commit` for its hooks. Optional: `terraform-docs`, without which
  `project-new` leaves the `terraform_docs` hook commented out.
- The `dev-standards` plugin, for `precommit-standards`.
- Optional: `claude-craft`, for `config-audit`.

## Install

```
/plugin install project-scaffold@<your-marketplace>
```
