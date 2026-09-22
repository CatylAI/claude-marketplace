---
name: project-init
license: MIT
description: Generate a CLAUDE.md hierarchy (root, source, infrastructure) for an existing repository that already has code. Detects the project name, language, package manager, and the real build/test/lint commands, fills in the templates shipped with this plugin, and writes only CLAUDE.md files — no build files, no git operations, no remote repository. Use when onboarding an established repo to AI-assisted development or refreshing stale CLAUDE.md files. Not for auditing configuration that already exists, which is project-hooks, and not for recording architectural decisions, which is adr-init.
when_to_use: add CLAUDE.md, generate CLAUDE.md hierarchy, onboard an existing repo, refresh project memory files, set up Claude for this repo
user-invocable: true
allowed-tools: Read, Write, Bash(find:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(grep:*), Bash(mkdir:*), Bash(pwd:*), AskUserQuestion
argument-hint: "[project-name]"
context: fork
---

# Generate a CLAUDE.md Hierarchy

Writes CLAUDE.md files, and nothing else. It does not create a Makefile, configure hooks,
initialize git, or touch a remote.

## Step 1 — Read the repository, then decide what already exists

Run these and work from the output. Every fact this skill writes into a CLAUDE.md comes from
what they print:

```bash
pwd
find . -name CLAUDE.md -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null | head -10
ls package.json pyproject.toml requirements*.txt go.mod Cargo.toml pom.xml build.gradle* Gemfile composer.json 2>/dev/null
ls package-lock.json pnpm-lock.yaml yarn.lock uv.lock poetry.lock Cargo.lock go.sum 2>/dev/null
ls -d src lib app cmd pkg internal 2>/dev/null
ls -d test tests spec __tests__ 2>/dev/null
ls -d infra infrastructure deploy terraform charts 2>/dev/null; find . -maxdepth 3 -name '*.tf' -o -maxdepth 3 -name 'docker-compose*.y*ml' -o -maxdepth 3 -name 'Chart.yaml' 2>/dev/null | head -5
ls Makefile Taskfile.y*ml justfile 2>/dev/null
```

In order: the current directory, existing CLAUDE.md files, manifests, lock files, source
directories, test directories, infrastructure signals, and the task runner.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and wait for it. Do not guess the stack: a CLAUDE.md generated from assumptions describes a
repository that does not exist, and its commands will be run.

Then, if a root `CLAUDE.md` exists, ask via `AskUserQuestion` before touching it:

- **Merge** — keep existing content, add the missing sections. Default choice; it preserves
  hard-won project knowledge.
- **Overwrite** — replace it with a fresh generated file.
- **Skip root** — leave it alone, generate only the subdirectory files.

Never overwrite silently. Any existing "Common mistakes" or equivalent section is preserved
verbatim on a merge — that content cannot be regenerated.

## Step 2 — Detect the project facts

Read, do not guess. Derive each value from a file that actually exists:

| Fact | Where it comes from |
| --- | --- |
| Project name | manifest name field, else the directory name |
| Language + version | manifest, version pin file (`.nvmrc`, `.python-version`, `go.mod`, `rust-toolchain`) |
| Package manager | lock file present |
| Framework | notable dependency in the manifest |
| Install / build / test / lint commands | the manifest's script block, or the task runner's targets, or the CI config |
| Source, test, infra directories | the directory listing |

Read the task runner file (`Makefile`, `Taskfile.yml`, `justfile`) if present — its targets
are usually the truest statement of how the project is actually driven, and they beat any
default you would otherwise invent.

If two ecosystems are present (for example a Python service with a JavaScript frontend), ask
which is primary rather than picking one. A polyrepo-in-one-repo gets a CLAUDE.md per
subproject, not one confused file.

If a command cannot be determined, leave the placeholder and mark it `TODO: confirm` rather
than filling in a plausible-looking command. A wrong command in CLAUDE.md is actively
harmful — it will be run.

## Step 3 — Confirm the shape

Use `AskUserQuestion` for what detection cannot settle:

1. **Is this infrastructure-only?** If yes, skip the source-level file.
2. **Which files should be written?** Offer root, source, infrastructure as a multi-select,
   pre-selected according to what was detected.

Show the detected facts in the question text so the user can correct a bad detection before
anything is written, not after.

## Step 4 — Fill the templates

Templates ship with this plugin at `${CLAUDE_PLUGIN_ROOT}/templates/claude-md/`:

| Template | Written to | When |
| --- | --- | --- |
| `root.md` | `./CLAUDE.md` | Always (unless the user chose Skip root) |
| `src.md` | `<source dir>/CLAUDE.md` | A source directory exists and the repo is not infra-only |
| `infra.md` | `<infra dir>/CLAUDE.md` | Infrastructure files were detected |

Read each template, substitute every `${PLACEHOLDER}` from Step 2, and write the result.
Placeholders that could not be resolved stay visible as `TODO: confirm <what>` — never
delete a section because a value was missing, and never invent the value.

Create a target directory only if the user asked for a file in it. Do not conjure a `src/`
that the project does not have.

## Step 5 — Verify and report

```bash
find . -name CLAUDE.md -not -path './node_modules/*' -not -path './.git/*'
```

Confirm the listing matches what Step 3 approved. If a file is missing, say so and rewrite
it rather than reporting success.

Then report:

- every file written, with its one-line purpose,
- every placeholder left as `TODO: confirm`, so the user knows what to finish,
- the suggested next steps: `adr-init` to record the architectural decisions this repo
  already embodies, and `project-hooks` to audit the repo's `.claude/` wiring.

## Notes

- The templates are yours to edit. This skill reads whatever is in
  `${CLAUDE_PLUGIN_ROOT}/templates/claude-md/`, so house style changes there, not here.
- Keep each file short. A CLAUDE.md that nobody reads to the end is a CLAUDE.md that does
  not work; commands and constraints earn their space, prose does not.
- Do not duplicate content across levels. A subdirectory file states what differs, not what
  the root already said.
