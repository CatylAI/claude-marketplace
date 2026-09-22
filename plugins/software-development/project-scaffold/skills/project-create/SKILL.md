---
name: project-create
license: MIT
description: Router for a vague "set this project up" request. Inspects the working directory, asks at most two questions, and names exactly one skill to run — project-new for an empty directory, project-init for a repo that already has code, project-hooks to audit existing .claude/ wiring, adr-init to record decisions the code already made, poc-start for a time-boxed experiment. Also says plainly when the answer is none of them, because the user wants a remote repository created. Scaffolds nothing itself. Use when "start a new repo" or "set up this project" could mean several things and picking wrong would overwrite files or scaffold nothing.
when_to_use: set up a project, start a new repo, bootstrap this directory, which scaffolding skill do I want, not sure where to start, scaffold something here
user-invocable: true
allowed-tools: Read, Bash(pwd:*), Bash(ls:*), Bash(find:*), Bash(git:*), AskUserQuestion
argument-hint: "[what you want to set up]"
---

# Which Scaffolding Skill Do I Want

Routes one vague request to exactly one skill. This skill writes nothing, creates nothing,
and runs no scaffolding of its own. It inspects, asks, and names the route.

It earns its place because two of the targets are genuinely easy to confuse, and both
failure modes are expensive: running `project-new` in a directory that already has code can
overwrite real files, and running `project-init` in an empty one produces a CLAUDE.md
describing a project that is not there.

## The routes

| Want | Precondition | Skill | What you get |
| --- | --- | --- | --- |
| The full local skeleton | Directory is empty | `project-new` | CLAUDE.md hierarchy, Makefile, pre-commit config, README, `.gitignore`, initial commit |
| A CLAUDE.md hierarchy | Repository already has code | `project-init` | CLAUDE.md files only, generated from detected project facts |
| To check the Claude wiring | Any repository | `project-hooks` | Audit and repair of `CLAUDE.md`, `.claude/settings.json`, project agents and skills |
| The architecture written down | Repository has decisions but no `docs/adr/` | `adr-init` | A proposed ADR set plus its index, written only after you approve |
| To answer a question, not build a thing | Anything | `poc-start` | A POC contract: the question, the kill criteria, the time box, a thin scaffold |
| A remote repository created and pushed | — | **Not this plugin** | See below |

### The remote is not ours

This plugin never creates a remote repository, adds a remote, pushes, sets branch
protection, or opens a pull request. If that is what the user is asking for, say so directly
rather than routing to the nearest local skill and leaving them to discover the gap.

Forge work lives in the `github-workflow` plugin — pull request lifecycle, review transport,
and GitHub Actions authoring. Creating the repository itself is the user's own step, run
against their forge (`gh repo create <owner>/<repo>`, or the forge's web interface). The
usual sequence is: `project-new` for the local skeleton, then create the remote, then wire
CI.

## Step 1 — Look before you ask

```bash
pwd
ls -A 2>/dev/null | head -20
git rev-parse --show-toplevel 2>/dev/null || echo "(not a git repo)"
git remote -v 2>/dev/null | head -2
find . -maxdepth 1 -name CLAUDE.md -o -maxdepth 1 -name .poc -o -maxdepth 1 -name .claude
find . -maxdepth 2 -path ./docs/adr -o -maxdepth 2 -name '*.py' -o -maxdepth 2 -name '*.ts' -o -maxdepth 2 -name '*.tf' 2>/dev/null | head -5
```

Classify the directory into exactly one of these before asking anything:

- **Empty or near-empty** — nothing but `.git` and stray dotfiles. Candidates: `project-new`,
  `poc-start`.
- **Has source code** — candidates: `project-init`, `project-hooks`, `adr-init`.
- **Already a POC** — `.poc/` exists. Do not route to `poc-start`; it refuses to
  double-start. The live routes are `poc-validate` and `poc-graduate`, both in this plugin.

If the classification is unambiguous *and* the user's wording already settles the intent,
name the route and stop. A router that asks a question whose answer is already on screen is
just friction.

## Step 2 — Resolve the intent

Use `AskUserQuestion` with the one question the directory state cannot answer.

If the directory is empty, the open question is project versus experiment:

```
AskUserQuestion(questions: [{
  header: "New work",
  question: "Is this a project you intend to keep, or an experiment that should end in a yes/no?",
  options: [
    { label: "A real project",
      description: "Full local skeleton: CLAUDE.md hierarchy, Makefile, pre-commit, README, .gitignore, initial commit. Run project-new." },
    { label: "An experiment",
      description: "Write the question, the kill criteria and the time box first, then scaffold the minimum. Run poc-start." }
  ]
}])
```

If the directory has code, the open question is what kind of work is wanted on it:

```
AskUserQuestion(questions: [{
  header: "Existing repo",
  question: "What does this repo need?",
  options: [
    { label: "CLAUDE.md files",
      description: "Generate a root/source/infrastructure CLAUDE.md hierarchy from detected project facts. Run project-init." },
    { label: "Config audit",
      description: "Check .claude/settings.json validity, hook wiring, permissions and agent/skill discoverability, then fix what you approve. Run project-hooks." },
    { label: "Decisions recorded",
      description: "Survey the code, extract the architectural decisions it already encodes, propose docs/adr/. Run adr-init." }
  ]
}])
```

Ask one question. If the answer to the first makes a second genuinely necessary, ask it;
otherwise stop. Three questions to pick one skill is worse than picking the wrong one and
being corrected.

## Step 3 — The distinction that actually matters

`project-new` and `project-init` overlap in the user's head and not at all on disk:

- `project-new` **assumes the directory is empty** and writes a whole skeleton into it,
  including build files and a commit. Pointed at a real repository it can overwrite a
  Makefile, a README, or a `.gitignore` that someone wrote on purpose.
- `project-init` **assumes the code already exists** and reads it — the manifest, the lock
  file, the task runner — to derive the real commands before writing CLAUDE.md files, and
  writes nothing else. Pointed at an empty directory it has nothing to detect and produces a
  CLAUDE.md full of `TODO: confirm`.

So the routing rule is the directory state, not the user's phrasing. "Set up a new project"
said inside a checkout with three years of history means `project-init`. Confirm the state
with the Step 1 listing before you believe the words.

The second confusable pair is `project-init` versus `project-hooks`: one **generates** the
CLAUDE.md hierarchy, the other **inspects and repairs** what a repo already has, settings
and hooks included. Generate when there is nothing; audit when there is something you
suspect is stale, broken, or quietly permissive.

## Step 4 — Hand off

Every route target in this plugin runs in a forked context and cannot be launched from here
with the `Skill` tool. Name the command for the user to type:

> This repository already has code and no CLAUDE.md, so the route is **`/project-init`** —
> it will read your manifest and task runner and generate the hierarchy from what is
> actually there.

Always state the route **and** the one-line reason. The reason is what lets the user
override you when the directory listing misled you — a vendored dependency tree can make an
empty project look populated, and only the user knows that.

If the answer was the remote, say that instead, and do not offer a local skill as a
consolation route:

> Creating and protecting the remote is outside this plugin. Run `project-new` for the
> local skeleton, create the repository on your forge yourself, then use the
> `github-workflow` plugin for pull requests and Actions.

## Notes

- Never route to a skill that would refuse. `.poc/` present means `poc-start` will stop;
  route to `poc-validate` or `poc-graduate` instead.
- Never chain routes. Name one skill. Sequencing advice belongs in the one-line reason, not
  in a queue of skills the user did not ask for.
- If the directory state and the stated intent genuinely conflict — an empty directory and
  "audit my config" — surface the conflict rather than silently trusting one of them.
