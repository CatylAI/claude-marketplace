# Plan and baseline formats

The plan→execute contract. `upgrade-plan` writes these files; `upgrade-execute` reads them. Every
field and enum here is closed: a value outside the listed set is a defect in the plan, and
`upgrade-execute` stops on it instead of guessing.

## Contents

- Working directory layout
- Gate run summary (baseline and per step)
- Plan file
- Step block
- Examples

## Working directory layout

Everything the pipeline writes lives under `.upgrade/` at the repository root.

```
.upgrade/
  .gitignore           one line: *   (ignores the directory itself, so nothing here is ever committed)
  plan.md              the plan
  baseline/
    summary.md         gate run summary for the tree before any upgrade
    <gate>.log         full output of each gate command
  steps/<n>/           written by upgrade-execute, one directory per step number
    summary.md
    <gate>.log
  steps/final/         upgrade-execute's last run of every baseline gate on the final HEAD
  report.md            written by upgrade-execute: a status line per step as it runs, the report at the end
```

The self-ignoring `.gitignore` keeps these files out of `git status` and out of every commit without
touching the repository's own `.gitignore` or the protected `.git/` directory.

## Gate run summary

One file per run of the gates: `.upgrade/baseline/summary.md`, `.upgrade/steps/<n>/summary.md`, or
`.upgrade/steps/final/summary.md`. Create the directory with `mkdir -p` before redirecting a gate's
output into it; a redirect into a missing directory fails with exit 1, which reads as a failing gate.

```markdown
# Gate run
Run: baseline | step <n> | final
HEAD: <40-character commit SHA the gates ran against>
Clean tree: yes | no

| Gate | Command | Exit | Tests run | Failed tests |
| --- | --- | --- | --- | --- |
| <gate id> | `<exact command, as run from the repo root>` | <integer> | <integer> or unknown or n/a | none, or a comma-separated list of test identifiers, or n/a |
```

Gate ids are `<kind>` or `<kind>:<label>` (for example `test:integration`). `<kind>` is one of:
`test`, `typecheck`, `lint`, `build`, `tf-validate`, `tf-fmt`, `tf-plan`.

- **Command** is the command the project itself uses (from its CI definition, `package.json`
  scripts, `Makefile`, `tox.ini`, `noxfile.py` and similar), so that `upgrade-execute` can re-run it
  verbatim. Use the non-fail-fast form where the runner has one (`cargo test --no-fail-fast`), so
  the failing set is complete.
- **Tests run** comes from the runner's own summary line. Write `unknown` when the runner prints no
  count, and `n/a` for gates that are not test runners.
- **Failed tests** lists identifiers exactly as the runner prints them, so that a later run can be
  compared by set membership.
- **Exit** for `tf-plan` uses `terraform plan -detailed-exitcode`: 0 no changes, 1 error, 2 changes
  present. Include `tf-plan` only when it runs on the baseline, since it needs backend access and
  credentials; when it cannot run, leave it out and name it under `Input gaps`.

## Plan file

`.upgrade/plan.md`. Sections appear in this order, with these exact headings.

```markdown
# Upgrade plan
Plan-Format: 1
HEAD: <40-character SHA the plan and baseline were made against>
Baseline: .upgrade/baseline/summary.md | none (no gates) | none (no checkout)
Adequacy: adequate | partial | inadequate | not-assessed
Decision: proceed | proceed-unverified | fix-baseline-first | add-tests-first | stop
Decided by: gate | user

## Adequacy
<The evidence for the verdict: baseline result, which rows the falsification check covered and
what happened, which dev-standards skills the suite was judged against or "standards not
available". For partial: the unverifiable step numbers, by name.>

## Conflicts
<One bullet per coupling found: the packages, the shared constraint, quoted resolver output. Or
"None found", followed by the commands that were run.>

## Steps
<One step block per step, in execution order.>

## Not in this plan
| ID | Name | Reason | Detail |
| --- | --- | --- | --- |
| <research ID> | <Name> | already-current, deferred-major, blocked-ceiling, needs-ceiling, blocked-external, not-worth-churn or needs-research | <one sentence, naming what would unblock it> |

## Input gaps
<Research columns that were missing or unknown, row by row, and how each affected the plan. Or "None".>
```

`Decision` rules: `adequate` → `proceed` (`Decided by: gate`). Any other verdict needs a choice
from the user (`Decided by: user`). `upgrade-execute` runs only when `Decision` is `proceed` or
`proceed-unverified`.

`Baseline: none (no gates)` allows only `Decision: proceed-unverified` or `stop`, and every step is
then `Verification: unverifiable (no gates)` with `Gates: none`.

Every research `ID` appears exactly once, in one step's `Rows` or in `Not in this plan`. The one
exception is a row planned as an in-major step followed by a major step: its `ID` appears in exactly
those two steps, and the major step lists the in-major step in `Depends on`.

## Step block

```markdown
### Step <n>: <one-line title>
- Rows: <research IDs this step moves, comma-separated>
- Changes: <file>: <name> <from> -> <to>; <file>: ...
- Apply: `<exact command>`; `<exact command>`
- Group: single | atomic (<each member and why it cannot move alone>)
- Depends on: none | <step numbers, comma-separated, all lower than n>
- Rank: 1 | 2 | 3 | 4 | 5
- Bound by: upstream | ceiling | breaking
- Deployment-pinned: no | yes (<the pin: runtime identifier, cluster version, workspace CLI pin, image tag>)
- Breaking changes: none (minor or patch) | none found (searched: <APIs searched>) | <file:line> <what changes>; ...
- Behaviour changes: none | <change from the release notes> -> <code path it affects>
- Verification: verifiable | unverifiable (<why: no suite, falsification stayed green, gate missing>)
- Gates: <gate ids from the baseline summary, comma-separated> | none
- Rollback: <how to undo this step alone once committed, normally `git revert --no-edit <sha>` then the restore command>
- Why: <the ordering derivation, one sentence naming the constraint>
```

- `Changes` names every manifest and lockfile the step touches, with exact from and to versions.
- `Apply` lists the package-manager commands `upgrade-execute` runs. Manifest edits in `Changes`
  that no command performs (a `.nvmrc`, a Dockerfile tag, a Terraform constraint) are made by hand
  first; lockfiles are only ever regenerated by a command, never edited.
- `Rank` is the priority rank carried from the research table. For a step with several rows, it
  is the smallest `Rank` number among them (the most urgent row sets the step's priority).
- `Deployment-pinned: yes` makes `upgrade-execute` ask the user before the step runs.

## Examples

<example>
A patch-level step with no couplings:

```markdown
### Step 3: express 4.19.2 -> 4.21.2
- Rows: I3
- Changes: package-lock.json: express 4.19.2 -> 4.21.2 (package.json unchanged: its `^4.18.0` already allows 4.21.2)
- Apply: `npm update express`
- Group: single
- Depends on: none
- Rank: 3
- Bound by: breaking
- Deployment-pinned: no
- Breaking changes: none (minor or patch)
- Behaviour changes: none
- Verification: verifiable
- Gates: test, typecheck, lint
- Rollback: `git revert --no-edit <sha>` then `npm ci`
- Why: independent row; rank 3 (advisory against 4.19.2) orders it after the rank 1 and 2 steps.
```
</example>

<example>
An atomic runtime step whose deployment target pins the version:

```markdown
### Step 1: Node 20 -> 22 across runtime pins
- Rows: I1, I2, I7, I9
- Changes: .nvmrc: node 20.11.1 -> 22; package.json: engines.node >=20 -> >=22; Dockerfile: node:20-alpine -> node:22-alpine; infra/lambda.tf: runtime nodejs20.x -> nodejs22.x; package.json: @types/node ^20 -> ^22; package-lock.json: regenerated
- Apply: `npm install --save-dev @types/node@^22`
- Group: atomic (every runtime pin must agree or CI and deploy test different runtimes; @types/node must match the runtime major or the typecheck gate reports wrong APIs)
- Depends on: none
- Rank: 1
- Bound by: ceiling
- Deployment-pinned: yes (Lambda runtime identifier in infra/lambda.tf)
- Breaking changes: src/files.ts:14 and src/files.ts:52 call an API the Node 22 release notes list as removed; each moves to the documented replacement
- Behaviour changes: none
- Verification: verifiable
- Gates: test, typecheck, lint, build
- Rollback: `git revert --no-edit <sha>` then `npm ci`
- Why: rank 1 runtime (I1 is out of support); the research table's ceiling is 22.x, so 22 and no higher.
```
</example>
