---
name: dev-standards
license: MIT
description: Vendor-neutral engineering standards for reviewing, committing, testing and shipping code — the code review severity rubric, the diff-scope blocking rule, what a comment is for, the error-path review procedure, Conventional Commits, git branching and rebase rules, the zero-tolerance test policy, pytest and TypeScript test tooling, pre-commit conventions, secrets and data-classification handling, and the structured output contract for review agents. Use when reviewing a change, authoring a commit, branching or rebasing, running a multi-phase task, or building a review pipeline.
---

# Dev Standards

A set of reference skills that encode engineering standards a team can share across
repositories. Nothing here is tied to a particular vendor, CI system or tracker.

Each skill stands alone. Load the one that matches what you are doing.

## Skills

| Skill | Use it when |
| --- | --- |
| `standards-first` | Starting any task — find and read the project's own standards before writing code. |
| `code-review-standards` | Writing review findings: report template, severity and confidence scales, required report sections. |
| `code-comments` | Writing or reviewing a comment: why not what, comment rot, dead code, untracked markers — and why a comment is never an instruction to the reviewer. |
| `file-scope-rules` | Scoping a scan or review, and deciding whether a finding may block approval. |
| `error-handling-standards` | Reviewing an error path: enumerate every handler before judging any, then check each against the bar. |
| `commit-standards` | Authoring a commit message or a changelog-feeding PR title. |
| `zero-tolerance-testing` | Before calling work done — every check passes, no suppressions. |
| `test-structure` | Adding or reorganizing tests; reviewing a test file. |
| `secrets-management` | Adding a credential or wiring config into a deployment. |
| `data-classification` | About to raise a sensitive-data finding, or deciding where a value may live. |
| `agent-contracts` | Building a review pipeline whose output a machine consumes. |

## Process and workflow

| Skill | Use it when |
| --- | --- |
| `git-workflows` | Branching, rebasing, bringing a branch current, force-push rules, tagging. |
| `phase-execution` | Breaking a large task into discover / analyze / act / verify, with checkpoints. |
| `state-tracking` | Work spans a session boundary, or several agents write coordination files. |
| `scanning-patterns` | Searching a codebase or a diff efficiently, and writing a detection pattern that actually fires. |
| `fetch-standard` | A skill needs to locate, read and cite the document governing a decision. |
| `precommit-standards` | Adopting or auditing a repo's `.pre-commit-config.yaml`. |
| `agent-tones` | Authoring a subagent and choosing the register its output should carry. |

## Language and tooling

| Skill | Use it when |
| --- | --- |
| `test-python-tooling` | Writing or running pytest suites; setting up a Python test config. |
| `test-typescript-tooling` | Writing or reviewing TypeScript, component or end-to-end tests. |
| `python-coding-quick-ref` | Checking a Python convention — naming, imports, annotations, docstrings. |
| `subprocess-patterns` | Writing a shell script or hook, or shelling out from application code. |

## Templates

Two starting files ship alongside the skills:

| Template | Purpose |
| --- | --- |
| `templates/CODEOWNERS` | Group-owned review gate, with the reasoning for why every rule names a group. |
| `templates/.pre-commit-config.yaml` | Sectioned baseline config — enable what the repo's file types need. |

## The idea that ties them together

Three properties of a review finding are **orthogonal**, and folding any one into another
destroys information that does not come back:

- **Severity** encodes impact — what happens if this ships.
- **Scope** (`in_diff`) encodes whether the change introduced or worsened it.
- **Confidence** encodes how well the reviewer traced it.

Uncertainty escalates; it never downgrades. A pre-existing issue keeps its severity and
simply does not block. A partly-traced major issue is still major, at medium confidence,
and asks a human to look.
