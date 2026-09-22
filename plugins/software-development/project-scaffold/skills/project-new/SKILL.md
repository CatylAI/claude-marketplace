---
name: project-new
license: MIT
description: Scaffold a complete project skeleton into an empty directory — a CLAUDE.md hierarchy, a Makefile whose targets match the stack, a pre-commit config, a README, a .gitignore, and an initial commit on a local branch. Asks the project type (Python, TypeScript, Terraform, or a combination) and writes real runnable files rather than placeholders. Creates nothing remote — no repository, no push, no branch protection, no pull request. Use when the directory is empty and you want the whole local skeleton in one pass. Not for a repository that already has code, which is project-init, and not for a time-boxed experiment, which is poc-start.
when_to_use: start a new project from scratch, scaffold an empty directory, create a project skeleton, set up a Makefile and pre-commit, new repo local files, initial commit for a new project
user-invocable: true
allowed-tools: Read, Write, Bash(pwd:*), Bash(ls:*), Bash(find:*), Bash(mkdir:*), Bash(git:*), Bash(make:*), Bash(pre-commit:*), AskUserQuestion
argument-hint: "[project-name]"
context: fork
---

# Scaffold a New Project Locally

Turns an empty directory into a working project skeleton: documentation, a task runner,
quality hooks, ignore rules, and one commit that contains all of it.

Everything this skill does happens on the local filesystem. It does not create a remote
repository, add a remote, push, protect a branch, or open a pull or merge request. Those
are forge operations and they live in a forge plugin.

## Step 1 — Establish the starting state

Read the directory before writing anything:

```bash
pwd
ls -A 2>/dev/null | head -20
ls -A 2>/dev/null | wc -l | tr -d ' '
find . -maxdepth 1 -name .git -type d
```

Classify what you found:

- **Empty, or only `.git` and stray dotfiles** — proceed.
- **Has real files** — stop and ask before continuing. A directory with source in it is
  `project-init`'s case (generate CLAUDE.md files against code that already exists), not
  this one. Offer `AskUserQuestion` with two options: continue anyway and risk overwriting,
  or abort and run `project-init` instead. Default to aborting. Never overwrite silently.

If `.git` is already present, keep it. Re-initializing a repository that already has history
is not something to do on the user's behalf.

## Step 2 — Ask what is being built

Use `AskUserQuestion`. Three things have to be settled before any file is written, and none
of them can be guessed safely.

**Project type.** Offer:

- Python service or library
- TypeScript / JavaScript application
- Infrastructure only (Terraform)
- A combination — application code plus infrastructure

**Project name.** Default to the directory name, shown in the question text so the user can
correct it. It becomes the package or module name, so hold it to what the ecosystem allows:
kebab-case for the repository and the npm package, snake_case for the Python import name.

**Infrastructure approach.** Offer:

- Terraform only
- Terraform plus a local runtime definition (a container compose file)
- None — source code only

Every later step reads these three answers. Do not start writing files until all three are
settled.

## Step 3 — Create the directory skeleton

Only directories the chosen shape actually needs. An empty directory nobody uses is noise in
every future listing.

Python service:

```bash
mkdir -p src/<package_name> tests
```

TypeScript application:

```bash
mkdir -p src tests
```

Infrastructure, when Terraform was chosen:

```bash
mkdir -p infrastructure/terraform/modules infrastructure/terraform/environments
```

Add `infrastructure/local/` only if the user asked for a local runtime definition. Do not
create a `docs/` tree here — `adr-init` creates `docs/adr/` when the user is ready for it.

## Step 4 — Write the CLAUDE.md hierarchy

The templates ship with this plugin at `${CLAUDE_PLUGIN_ROOT}/templates/claude-md/`:

| Template | Written to | When |
| --- | --- | --- |
| `root.md` | `./CLAUDE.md` | Always |
| `src.md` | `src/CLAUDE.md` | Any type other than infrastructure-only |
| `infra.md` | `infrastructure/CLAUDE.md` | Terraform was chosen |

Read each template and substitute every `${PLACEHOLDER}` from the Step 2 answers and the
commands you are about to put in the Makefile. The two must agree — a CLAUDE.md that names
a `make test` target the Makefile does not define is worse than no CLAUDE.md, because it
will be run.

Anything you genuinely cannot fill stays visible as `TODO: confirm <what>`. Never invent a
plausible-looking value to make the file look finished.

## Step 5 — Write the Makefile

The Makefile is the project's public interface: one place that states how to install, test,
check, and ship. Keep the target names identical across projects so muscle memory carries
over, and let the bodies differ by stack.

Recipe lines must be indented with a **tab**, not spaces. This is the single most common way
a generated Makefile fails on first use.

Python, using `uv` and the Astral toolchain:

```makefile
.PHONY: install test lint format typecheck verify

install:
	uv sync

test:
	uv run pytest

lint:
	uv run ruff check .

format:
	uv run ruff format .

typecheck:
	uv run mypy .

verify: lint typecheck test
```

TypeScript, using the package manager whose lock file you created:

```makefile
.PHONY: install build test lint typecheck verify

install:
	npm ci

build:
	npm run build

test:
	npm test

lint:
	npm run lint

typecheck:
	npm run typecheck

verify: lint typecheck test build
```

When Terraform is in the picture, add per-environment plan and apply targets rather than one
target that takes the environment as a variable — an explicit `plan-dev` is harder to point
at production by accident than `plan ENV=dev` with a wrong default:

```makefile
.PHONY: fmt validate plan-dev apply-dev

fmt:
	terraform -chdir=infrastructure/terraform fmt -recursive

validate:
	terraform -chdir=infrastructure/terraform validate

plan-dev:
	terraform -chdir=infrastructure/terraform plan -var-file=environments/dev.tfvars

apply-dev:
	terraform -chdir=infrastructure/terraform apply -var-file=environments/dev.tfvars
```

`verify` is the contract: one command that has to pass before a change is considered done.
For a combined project, make `verify` depend on the application checks and the infrastructure
`fmt` and `validate` targets both.

## Step 6 — Write the pre-commit configuration

`.pre-commit-config.yaml` catches the cheap mistakes before they reach history. Start with
the hygiene hooks every project wants, then add the stack's own.

Pin each `rev` to a real released tag — look up the current one rather than reusing a version
from memory, and never point a `rev` at a moving branch. An unpinned hook means the checks
that run today are not the checks that run tomorrow.

Hygiene, for every project — from `pre-commit/pre-commit-hooks`:

- `trailing-whitespace` and `end-of-file-fixer`
- `check-yaml` and `check-json`
- `check-added-large-files`
- `check-merge-conflict`
- `detect-private-key`

Python — from `astral-sh/ruff-pre-commit`, the `ruff` hook with `args: [--fix]` and the
`ruff-format` hook. Add `mypy` from `pre-commit/mirrors-mypy` if the project is typed, and
list its runtime stubs under `additional_dependencies` — without them it type-checks against
an empty environment and reports nonsense.

TypeScript — `prettier` over JavaScript, TypeScript, JSON, YAML, and Markdown, and `eslint`
restricted to source files. Prefer the repository's own `npm run lint` through a `local` hook
when the project already has an ESLint configuration; two sources of lint truth disagree
eventually.

Terraform — from `antonbabenko/pre-commit-terraform`, `terraform_fmt` and
`terraform_validate`. Add `terraform_tflint` only if the project has a `.tflint.hcl`; a hook
with no configuration fails on first run and gets disabled, which costs more than it saved.

Secrets scanning belongs here too if the project will ever hold credentials-adjacent
configuration. Say so in the report rather than adding a scanner the user did not ask for.

## Step 7 — Write the README

The README is for a human arriving cold. It is not the CLAUDE.md, and it should not repeat
it. Keep it to: what this is in one or two sentences, how to install and run it, how to run
the checks, and where the conventions live.

```markdown
# <project-name>

<one-sentence description — TODO: confirm>

## Quick start

    make install
    make verify

## Development

Conventions and commands for this project live in [CLAUDE.md](./CLAUDE.md).
Infrastructure conventions live in `infrastructure/CLAUDE.md`.

## Contributing

Branch from the default branch, make the change, and run `make verify` before
proposing it. The check that gates a change is the same one CI runs.
```

Leave the description as an explicit TODO rather than generating marketing prose about a
project that does not exist yet.

## Step 8 — Write the .gitignore

Cover the ecosystems actually chosen, plus the two categories every project needs:
environment files and editor state. Grouped and commented, so the next person can tell which
lines are load-bearing:

- **Environment** — `.env`, `.env.*`, and any local secrets file the stack uses. First
  group in the file, because it is the one whose absence causes real damage.
- **Python** — `__pycache__/`, `*.py[cod]`, `.venv/`, `.mypy_cache/`, `.pytest_cache/`,
  `.ruff_cache/`, `*.egg-info/`, `dist/`, `build/`.
- **Node** — `node_modules/`, build output for the chosen framework, `.turbo/`, coverage
  output.
- **Terraform** — `.terraform/`, `*.tfstate`, `*.tfstate.*`, `crash.log`, and `*.tfvars`
  files that hold environment-specific values you do not want committed. Keep
  `.terraform.lock.hcl` **tracked** — it pins provider hashes, and ignoring it is a
  reproducibility bug, not a tidiness win.
- **Editor and OS** — `.idea/`, `.vscode/`, `.DS_Store`, swap files.

Do not ignore lock files. A committed lock file is what makes `make install` mean the same
thing on two machines.

## Step 9 — Make the first commit

```bash
git init
git add .
git commit -m "chore: scaffold project skeleton"
```

Three things to get right:

- If `git init` created the repository, check what it named the default branch and tell the
  user in the report. Do not rename it — that is a project convention, not this skill's call.
- Install the hooks so the config written in Step 6 is actually live:

  ```bash
  pre-commit install
  ```

  If `pre-commit` is not on PATH, say so in the report and give the install command rather
  than silently skipping. A `.pre-commit-config.yaml` with no installed hook is decoration.
- Use a Conventional Commits subject. The scaffold commit is the first line of the project's
  history and it sets the pattern everyone else copies.

Stop here. Do not add a remote, do not push, do not create a repository anywhere.

## Step 10 — Verify what was written

Check the artifacts rather than trusting that the writes landed:

```bash
git log --oneline -1
make -n verify >/dev/null 2>&1 && echo "verify target resolves" || echo "verify target BROKEN"
pre-commit run --all-files
```

`make -n verify` is the one that catches the tab-versus-spaces mistake and any target the
CLAUDE.md promised but the Makefile does not define. The first `pre-commit run` usually
reformats files — that is expected; commit the result with an `amend` or a follow-up
`style:` commit, and say which you did.

If anything fails, fix it and re-run. Do not report success over a broken target.

## Step 11 — Report

List every file written with a one-line purpose, then:

- every `TODO: confirm` left in the generated files, so the user knows what is unfinished;
- whether pre-commit hooks were installed or skipped, and why;
- the default branch name and the commit subject;
- the next steps, in order:
  1. Fill in the README description and the remaining CLAUDE.md TODOs.
  2. Run `adr-init` once the first real architectural decisions exist, so they are recorded
     while the reasoning is still fresh.
  3. Create the remote repository yourself when you are ready. This plugin does not do it,
     by design — forge work (remote creation, branch protection, CI workflows, pull request
     lifecycle) belongs to the `github-workflow` plugin and to your own forge tooling.
  4. Add CI once the remote exists. The `verify` target is what CI should run; a pipeline
     that runs a different set of checks than the developer does is a pipeline that
     disagrees with the developer.

## Notes

- The CLAUDE.md templates are yours to edit. This skill reads whatever is in
  `${CLAUDE_PLUGIN_ROOT}/templates/claude-md/`, so house style changes there, not here.
- Do not add a CI configuration file. Which CI system a project uses depends on where the
  remote will live, and the remote does not exist yet.
- Do not scaffold application code — no example endpoint, no placeholder component, no
  sample module. The skeleton is the deliverable; the first real file is the author's.
- If the user wanted a time-boxed experiment rather than a project, this is the wrong skill.
  `poc-start` writes a contract with kill criteria and scaffolds deliberately less.
