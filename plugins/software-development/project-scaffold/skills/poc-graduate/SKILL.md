---
name: poc-graduate
license: MIT
description: Close out a proof of concept with a decision — promote it to a real project on the target runtime chosen at poc-start, or kill it and record what was learned. Re-runs the validation as a gate, requires an explicit human decision when the evidence is mixed, writes an outcome record either way, and turns POC mode off. Use when a POC's time box is up or its question has been answered. Not for checking a POC without deciding its fate, which is poc-validate, and not for starting one.
when_to_use: graduate a POC, promote the prototype, kill the POC, close out the experiment, POC decision, make it a real project
user-invocable: true
context: fork
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(cat:*), Bash(ls:*), Bash(find:*), Bash(jq:*), Bash(mkdir:*), Bash(date:*), Bash(pwd:*), Bash(test:*), Task, AskUserQuestion
---

# Graduate or Kill a POC

Every POC ends in one of two ways. Both are successes: the point was to learn cheaply.
Ending in neither — the POC that simply continues — is the only failure.

## Step 1 — Gather context and verify there is a POC to close

Run these and work from the output:

```bash
pwd
test -f .poc/poc.json && echo present || echo "missing — not a POC"
date -u +%Y-%m-%d
```

In order: the current directory, whether a POC contract is present, and today's date — it is
the `closed_at` value written in Step 5 and the basis for "N days into an M-day box" in the
outcome record.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and the contents of `.poc/poc.json`, and wait for both. Closing a POC against an assumed date
or an unread contract writes a permanent record that is wrong.

If `.poc/poc.json` is absent, stop and say so. If `poc_active` is already `false`, report
the recorded outcome and stop — a POC is closed once.

Load the contract: name, question, success signal, kill criteria, time box, out-of-scope
list, and `target_runtime`.

## Step 2 — Gate on validation

Run the `poc-validate` checks and take its verdict as the input to this decision. Do not
proceed on a summary from memory or from the user; read the evidence.

- **Recommendation KILL** → go to Step 4. Do not offer graduation as the default path. If
  the user wants to override, that is their call to make explicitly, and the override plus
  its stated reason go into the outcome record.
- **Recommendation GRADUATE** → go to Step 3.
- **Recommendation EXTEND or a mixed picture** → present the verdicts and ask the user to
  decide with `AskUserQuestion`: graduate, kill, or keep going within the existing box. Do
  not decide a mixed case silently in either direction.

## Step 3 — Graduate

### 3a. Confirm the target runtime

Read `target_runtime` from the contract.

- If it names a runtime, confirm it still holds now that the evidence is in. The POC may
  have surfaced a constraint that rules it out — that is a finding, not an inconvenience.
- If it is `undecided`, decide it now with `AskUserQuestion`. Present the options the user
  names; this skill has no preferred platform and must not steer toward one.

Whatever is chosen, record it. The production plan is built around it.

### 3b. Write the production plan

Write `PRODUCTION-PLAN.md` in the new project. Derive the phases from what the POC actually
proved and what it deliberately skipped — the `out_of_scope` list from the contract is the
backbone of this plan, because every item on it is now in scope.

```markdown
# <name> — production plan

## What the POC proved

<the question, and the evidence that answered it — cited>

## What the POC did not address

<the out-of-scope list, each item now an explicit work item>

## Target runtime

<the runtime chosen at poc-start and confirmed here, and why>

## Phases

1. **Foundation** — the target runtime, environments, and the deployment path.
2. **Port the proven core** — carry over what the POC validated; leave behind what it
   scaffolded to move fast.
3. **The skipped concerns** — one work item per out-of-scope entry: access control,
   observability, failure handling, data lifecycle, cost controls, as applicable.
4. **Test coverage** — the POC's evidence becomes regression tests.
5. **Delivery** — CI, release process, rollback.

## Carried-over debt

<POC shortcuts that must not survive: hardcoded values, stubbed integrations,
in-memory state, missing error handling. Each one named, with its file.>
```

Be specific in "carried-over debt". This section is the single most valuable output of a
graduation, and it is only writable now, while the shortcuts are still remembered.

### 3c. Create the project

Create the production project in a new directory (default `../<name>`, confirmed with the
user). Copy across what was proven; leave behind POC scaffolding. Then run `project-init`
in the new directory to generate its CLAUDE.md hierarchy, and `adr-init` to record the
decisions the POC settled — the runtime choice, the stack, the approach the evidence
validated. Those decisions were just made with real evidence behind them, which is the
best possible moment to write them down.

Do not run git commands, create a remote, or open a merge or pull request. Tell the user
what to do and let them do it with their forge's own tooling.

## Step 4 — Kill

Killing a POC is a result, and it is recorded with the same care as a graduation.

Write `.poc/OUTCOME.md`:

```markdown
# <name> — outcome: killed

**Question:** <the question>
**Answer:** No — <one line>
**Closed:** <date>, <N> days into a <M>-day box

## What ended it

<the kill criterion that fired, and the evidence that fired it — cited>

## What we learned

<the findings worth keeping, including negative results and surprises.
A ruled-out approach is reusable knowledge; write it so the next person
does not spend the same week.>

## What is worth keeping

<code, benchmarks, test data, or measurements worth salvaging — with paths>

## What would change the answer

<the condition under which this is worth revisiting: a capability that does not
exist yet, a cost that has to fall, a constraint that has to lift>
```

The last section is what keeps a kill from being re-litigated every quarter.

## Step 5 — Turn POC mode off

Update `.poc/poc.json` in place — do not delete the contract, it is the record:

```json
{
  "poc_active": false,
  "outcome": "graduated | killed",
  "closed_at": "<ISO timestamp>",
  "closed_to": "<production directory, if graduated>",
  "decision_rationale": "<one line, including any human override of the validation verdict>"
}
```

Keep every original contract field alongside these. A contract that disappears when the POC
closes cannot be checked later.

## Step 6 — Report

State: the outcome, the evidence it rests on, the files written, and the next action —
either the production project's path and its plan, or the outcome record and what it says
would change the answer.

Do not soften a kill. "We learned X cheaply and stopped" is the intended result of a
well-run POC, and reporting it as a disappointment teaches the wrong lesson.
