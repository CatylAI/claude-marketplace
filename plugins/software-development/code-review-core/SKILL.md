---
name: code-review-core
description: "Forge-neutral code review over a plain git diff: deterministic detectors find what a linter finds, bounded judgement agents review only what a linter cannot, and a validation pass re-reads every cited line and owns the verdict. Use when reviewing a branch, a commit range, or a working-tree diff without any hosting-provider API — the whole pipeline runs on `git diff` and writes files under `.code-review/`. NOT a transport: it posts nothing, comments nowhere, and touches no issue tracker. Pair it with a transport plugin when findings need to reach a pull request."
license: MIT
user-invocable: false
---

# code-review-core

The vendor-neutral half of a code review pipeline. It knows about `git`, files, and linters. It
knows nothing about any hosting provider, issue tracker, or chat service — by design, so a transport
plugin can be layered on top without forking the judgement.

## The shape of a review

Three stages, communicating only through files in `.code-review/`. That is what makes each stage
independently runnable and independently testable.

```
1. DETECT   pipeline/review-scan.sh
            ruff bandit mypy pylint shellcheck gitleaks trivy tflint checkov tfsec
            + dependency pinning, commented-out code, changed-symbol impact
            -> SCAN.json, SCAN-SUMMARY.md          (zero tokens, reports, never enforces)

2. BOUND    pipeline/prepare-context.sh
            runs the scan, caps the diff, decides which gated agents spawn
            -> CONTEXT.json, DIFF.md

3. JUDGE    review-semantic                judges what no linter can      -> SEMANTIC.json
            review-testing                 test quality, on a gate        -> TESTING.json
            review-architect               design, on a gate              -> ARCHITECTURE.md
            review-authoring-conformance   Claude Code authoring, on a gate -> CLAUDE_CONFIG.json
            review-validator               re-reads every cited line      -> VALIDATED.{json,md}
```

`VALIDATED.json` present and parseable is the signal that the validator finished. Anything that gates
on this review depends on that invariant, which is why the validator writes it with the `Write` tool
rather than a shell heredoc.

## Why it is built this way

- **Deterministic first.** A linter beats an LLM at grep-shaped detection and costs nothing per run.
  Every mechanically-detectable defect is found before an agent is spawned, so agent budget is spent
  only on business logic, authorization, concurrency, error paths, test adequacy and design.
- **Bounded context.** `prepare-context.sh` caps the diff and records what it omitted. An agent that
  reads an unbounded repository spends its turns on orientation and reports on nothing.
- **Deterministic gates, not self-assessment.** Whether the architect, the testing agent, or the
  authoring-conformance agent runs is decided by `prepare-context.sh` before the agent exists — never
  by the agent's own judgement about whether the diff "looks like" its territory.
- **One owner of the verdict.** Only `review-validator` writes a verdict. Every other agent writes
  findings. Findings without a re-read are proposals, not results.

## Running it

```bash
# 1 + 2: detect and bound, in one call
pipeline/prepare-context.sh --base origin/main

# or just the detection pass, standalone
pipeline/review-scan.sh --base origin/main
```

Both write into `.code-review/`, which is fenced with its own `.gitignore` on creation so review
artifacts cannot be committed by accident.

Then spawn the judgement agents against the artifacts on disk, semantic first, validator last.

## The finding contract

Every agent writes the same ten-key finding shape, defined once in `pipeline/contract.py` and
generated from there into `pipeline/schemas/agent-contract.schema.json`:

```
id, severity, category, location, title, evidence, recommendation, ux_impact, in_diff, confidence
```

Three axes, none folding into another:

| Axis | Values | Means |
| --- | --- | --- |
| `severity` | `BLOCKER` `MAJOR` `MINOR` `NIT` | impact only |
| `in_diff` | `true` / `false` | did this change introduce or worsen it |
| `confidence` | `HIGH` `MEDIUM` `LOW` | how well the reviewer traced it |

A pre-existing defect **keeps its severity** and sets `in_diff: false` — scope is what stops it
blocking, not a relabel. An uncertain finding keeps its severity and escalates the verdict to
`INCOMPLETE`; it is never silently downgraded or dropped. The blocking floor
(`CODE_REVIEW_BLOCKING_FLOOR`) is the only knob, and it defaults to `MINOR`.

## What it deliberately does not do

- No API calls to any code-hosting provider, issue tracker, or chat service.
- No posting, commenting, approving, or merging.
- No enforcement from the scan: exit status is `0` whenever the scan completed, whatever it found.
  A scan that failed a pipeline because a linter is missing from the runner image would be worse
  than no scan at all.

## Dependencies

Requires `dev-standards`. The agents inject `code-review-standards`, `file-scope-rules` and
`agent-contracts` by name; without them they run with no output contract and write no
`VALIDATED.json`, silently.
