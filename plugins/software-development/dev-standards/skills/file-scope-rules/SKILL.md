---
name: file-scope-rules
license: MIT
description: Which files to include or exclude when scanning, reviewing or analyzing a codebase, plus the diff-scope rule that decides whether a review finding may block approval. Use before any repo-wide scan, audit, or pull request review.
---

# File Scope Rules

## Always exclude

| Pattern | Reason |
| --- | --- |
| `node_modules/`, `vendor/` | Vendored dependencies |
| `dist/`, `build/`, `out/`, `.next/`, `target/` | Build artifacts |
| `__pycache__/`, `.pytest_cache/`, `.mypy_cache/` | Language caches |
| `.git/` | Version control internals |
| `*.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `poetry.lock` | Machine-generated lockfiles |
| `.terraform/`, `.terragrunt-cache/` | Provider/module caches |
| `coverage/`, `.nyc_output/` | Coverage reports |
| `.env`, `.env.*` | Environment files — never read or quote these |
| `.worktrees/` | Working copies of the same repo |

Excluding lockfiles from *review* does not mean ignoring them: a dependency change
still matters, it just belongs in the manifest diff, not line-by-line.

## Always include

| Pattern | Reason |
| --- | --- |
| `src/`, `lib/`, `app/`, `pkg/`, `internal/` | Application source |
| `*.tf`, `*.tfvars` | Infrastructure as code |
| CI pipeline definitions | Deploy and gate behavior |
| `Dockerfile*`, `docker-compose*` | Container definitions |
| `Makefile`, `justfile`, `Taskfile.yml` | Build and task entry points |
| `*.test.*`, `*.spec.*`, `__tests__/`, `tests/` | Test files |

## Stack detection

| Marker file | Stack | Confidence |
| --- | --- | --- |
| `pyproject.toml`, `requirements.txt`, `setup.py` | Python | High |
| `tsconfig.json`, or `package.json` with a TypeScript dep | TypeScript | High |
| `package.json` without TypeScript | JavaScript | High |
| `go.mod` | Go | High |
| `Cargo.toml` | Rust | High |
| `pom.xml`, `build.gradle*` | JVM | High |
| any `*.tf` | Terraform | High |
| `next.config.*` | Next.js | High |
| `Dockerfile` | Containerized | Medium |

## Determining scope when none is given

1. **Changed files** — `git diff --name-only HEAD~1` or `git diff --staged --name-only`.
2. **Directory argument** — scope to that subtree if the caller named one.
3. **Whole repo** — only when explicitly requested. Warn if it exceeds ~500 files;
   a scan that large produces findings nobody reads.

## The diff-scope blocker rule (PR review)

**A finding may block approval only if the pull request introduced it or made it worse.**
A pre-existing issue in code the PR never touched is reported with `in_diff: false` and
**keeps whatever severity its impact earns** — it simply does not block. The sole
exception is a genuinely critical issue, below.

Scope and severity are separate axes. Capping out-of-diff findings at "nit" folds them
together and destroys information: a latent SQL injection ends up labelled like a
whitespace complaint, and every downstream consumer — the inline-comment selector, a
severity-filtered remediation pass, the next review of the same repo — loses the impact
signal permanently. `in_diff: false` already carries the "does not block" consequence.

This is the rule reviewers break most often. Over-escalating latent issues in untouched
code stalls correct changes and erodes author trust. Apply the causation test to every
finding before assigning severity.

### The causation test

Ask: **is the problematic line added or modified by this diff?**

```bash
git diff "origin/$TARGET_BRANCH...origin/$SOURCE_BRANCH" -- "$CITED_FILE"
```

| Where the root cause lives | `in_diff` | Severity | Blocks? |
| --- | --- | --- | --- |
| On a line added or modified by the diff | `true` | Whatever impact earns | Yes, at or above the blocking floor (a nit never blocks) |
| On an unchanged line that the diff **breaks** (a changed export breaks an existing consumer) | `true` — the change made it worse | Whatever impact earns | Yes, same as above |
| In unchanged code the diff does not affect — pre-existing, latent, "newly relevant", dead code, global gates the PR did not move | `false` | Whatever impact earns — **not capped** | No, unless critical |

The test is **causation, not proximity**. "This file matters more now because of the
feature" does not make a latent bug in it blocking. "A reader can reach this code from
the new path" does not either, when the new path is itself correct. Only "this change
created or worsened it" qualifies.

### The critical exception

An out-of-diff finding may still block only if it is genuinely critical:

- An actively exploitable security hole reachable in production — not theoretical, not
  config-gated, not dependent on trusted input turning hostile.
- Data loss or corruption that occurs on a normal code path.
- A live production-breaking defect, not a latent stub with zero callers.

The bar is high. "Could theoretically 404", "is a TODO stub", "repo coverage is under
threshold", "defense in depth would be nice" are not critical. When unsure, it is not
critical: report it with `in_diff: false` at its real severity and let scope keep it from
blocking. Do not relabel it.

### Reporting out-of-scope findings

Do not silently drop them and do not downgrade them. Report them with `in_diff: false`,
labelled `[PRE-EXISTING / OUT-OF-DIFF]`, plus one line noting they are not introduced by
this change and belong on a separate ticket. The signal and its magnitude both survive,
and a correct change still merges.

### Anti-patterns

- **Anchor-shopping.** Attaching a finding to a new test file because the buggy source
  file is not in the diff, then marking it blocking. Writing "anchored here since the
  source is not in this diff" is an admission about anchoring, not a judgement about
  impact. Either the diff genuinely breaks the unchanged code — re-anchor on the in-diff
  line and keep it blocking — or set `in_diff: false` and keep the severity.
- **Downgrading for uncertainty.** Certainty is `confidence`, not `severity`. A major
  issue you could only partly trace is a major issue at medium confidence, which should
  make the overall verdict *incomplete*. It is never a minor, never a nit, never dropped.
