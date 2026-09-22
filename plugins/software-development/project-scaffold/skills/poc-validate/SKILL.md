---
name: poc-validate
license: MIT
description: Read-only check of a proof of concept against the contract it wrote at the start — has the question been answered, has the success signal been observed, has any kill criterion been met, is the time box spent, and is there evidence for each claim. Reports MET, UNMET, or UNMEASURED per criterion and a recommendation to graduate, kill, or extend, but changes nothing. Use before deciding the fate of a POC, at a time-box checkpoint, or when a POC feels like it is drifting. Not for POCs that do not exist yet, and it never performs the graduation itself.
when_to_use: is this POC done, check kill criteria, POC checkpoint, should we keep going, validate a proof of concept, time box review
user-invocable: true
context: inline
allowed-tools: Read, Glob, Grep, Bash(cat:*), Bash(ls:*), Bash(find:*), Bash(grep:*), Bash(jq:*), Bash(date:*), Bash(git log:*), Bash(wc:*), Bash(pwd:*), Bash(test:*), Task
---

# Validate a POC Against Its Own Contract

This skill judges a POC by the criteria **it** wrote, not by general good practice. It is
read-only: it reports, it does not fix, scaffold, or migrate.

## Step 1 — Gather context and load the contract

Run these and work from the output:

```bash
pwd
test -f .poc/poc.json && echo present || echo "missing — not a POC"
date -u +%Y-%m-%d
```

In order: the current directory, whether a POC contract is present, and today's date — Step 2
compares it against `time_box.ends`.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and the contents of `.poc/poc.json`, and wait for both. Do not judge a time box against an
assumed date, and do not validate a contract you have not read.

If `.poc/poc.json` is absent, stop: this is not a POC. Suggest `poc-start` if one is
intended.

If it is present but `poc_active` is `false`, report that the POC is already closed, show
`graduated_at` / `killed_at` and the recorded outcome, and stop.

Read and restate the contract before judging anything: the question, the success signal,
each kill criterion, the time box, the out-of-scope list, and the target runtime. If the
user disagrees with the contract, that is a conversation to have before validation, not
during — a contract edited to match the result proves nothing.

## Step 2 — Assess the time box

Compare today against `time_box.ends`. Report one of:

- **Within the box** — days remaining.
- **At the box** — due now.
- **Past the box** — days over. Note that the time-box kill criterion has fired, and say so
  plainly even if the work looks promising. "Nearly there" past a deadline is the single
  most common way a POC turns into an unbudgeted project.

## Step 3 — Judge each kill criterion

For each entry in `kill_criteria`, assign exactly one verdict:

| Verdict | Meaning |
| --- | --- |
| `MET` | The criterion has fired. Evidence shows the condition that ends the POC. |
| `NOT MET` | Evidence shows the condition has not fired. |
| `UNMEASURED` | No evidence bears on this criterion either way. |

`UNMEASURED` is a real and common result, and it must never be reported as `NOT MET`.
Silence is not a pass. A criterion nobody measured is a question nobody answered.

Cite the evidence for every `MET` and `NOT MET`: the entry in `.poc/poc.json` evidence, a
test output, a benchmark file, a log. A verdict with no citation is an opinion — downgrade
it to `UNMEASURED` and say why.

## Step 4 — Judge the success signal

Has the observation named in `success_signal` actually been observed? Same three verdicts,
same evidence requirement. If the signal was a threshold, report the measured value against
the threshold, not a characterization of it.

## Step 5 — Check the evidence trail itself

```bash
jq '.evidence | length' .poc/poc.json 2>/dev/null
```

- **Empty** — the POC has produced no recorded observations. Report this at the top of the
  findings; it dominates everything else. A repository full of code with no evidence answers
  no question.
- **Sparse or undated** — note which criteria have no evidence attached.
- **Reconstructed** — if every entry shares one late date, say so; evidence written up at
  the end is weaker than evidence recorded as it happened.

## Step 6 — Check for drift

Scan for work that the contract put out of scope, and for the shape of a project rather than
an experiment:

```bash
find . -maxdepth 2 -name '*ci*.y*ml' -o -maxdepth 2 -name '.github' -o -maxdepth 2 -name '.circleci' 2>/dev/null | head -5
find . -name 'Dockerfile*' -not -path './.git/*' | wc -l
find . -name '*.tf' -o -name 'Chart.yaml' -not -path './.git/*' | head -5
```

Report drift as an observation, not a violation: deployment pipelines, multi-service
topologies, configuration abstraction layers, or hardening work inside a POC are time that
did not go into answering the question. Quantify it if you can — "three of the last ten
commits touched deployment plumbing" lands better than "there is scope creep".

Also check the reverse drift: has the POC stopped touching the question entirely? Compare
recent changes against the question's subject matter.

## Step 7 — Report

```markdown
## POC VALIDATION: <poc name>

**Question:** <question>
**Time box:** <start> → <end> — <within / at / N days past>

### Success signal

<signal> — **MET / NOT MET / UNMEASURED**
Evidence: <citation, or "none">

### Kill criteria

| Criterion | Verdict | Evidence |
|---|---|---|
| <criterion> | MET / NOT MET / UNMEASURED | <citation or none> |

### Evidence trail

<N entries; gaps noted>

### Drift

<out-of-scope work observed, or "none">

### Recommendation

**GRADUATE / KILL / EXTEND** — <one paragraph, grounded in the verdicts above>
```

Recommendation rules, applied in order:

1. Any kill criterion `MET` → **KILL**. That is what the criterion was for. Say which one.
2. Success signal `MET`, no kill criterion `MET` → **GRADUATE**.
3. Time box spent and the signal is `UNMEASURED` → **KILL**. The bet was time, and it is
   spent. If the user wants to continue, that is a new POC with a new contract and a new
   box — which is a decision someone makes deliberately, not a default.
4. Within the box, signal `UNMEASURED`, no criterion met → **EXTEND**, and name the specific
   measurement that would settle it.

Give the recommendation straight. A POC's whole value is that someone was willing to hear
"no" cheaply; softening the verdict destroys that value.

This skill changes nothing. To act on the recommendation, run `poc-graduate`.
