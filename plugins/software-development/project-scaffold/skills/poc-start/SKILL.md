---
name: poc-start
license: MIT
description: Frame a proof of concept before any code is written — the one question it answers, the falsifiable signal that would count as success, the kill criteria that end it, the time box, and the target runtime it would graduate onto. Writes .poc/poc.json plus a POC CLAUDE.md that keeps the work honest, then scaffolds only the minimum the author's chosen stack needs. Use when starting an experiment, spiking a risky idea, or being asked whether something is feasible. Not for a production repo, and not for a directory that already has a .poc/.
when_to_use: start a POC, proof of concept, spike, experiment, prototype, is this feasible, time-boxed investigation, kill criteria
user-invocable: true
context: fork
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(mkdir:*), Bash(ls:*), Bash(find:*), Bash(date:*), Bash(pwd:*), Bash(test:*), Task, AskUserQuestion
argument-hint: "<poc-name>"
---

# Start a Proof of Concept

A POC is a bet with a deadline, not a small project. It exists to answer **one** question.
If it cannot be stated as a question with an answer that could be "no", it is not a POC.

This skill writes the contract first. Scaffolding is the last step and deliberately thin.

## Step 1 — Look first, and refuse to double-start

Run these and work from the output:

```bash
pwd
test -d .poc && echo "yes — stop" || echo no
ls -A 2>/dev/null | head -20
date -u +%Y-%m-%d
```

In order: the current directory, whether a POC already exists here, what the directory holds,
and today's date — which becomes `time_box.started` in Step 3 and anchors the end date agreed
in Step 2.

If you cannot run commands here — a surface with no shell — ask the user to paste the output,
today's date included, and wait for it. Never invent the date a time box starts, and never
scaffold into a directory you have not listed.

If `.poc/` already exists, stop. Tell the user:

- to check the experiment against its own criteria, run `poc-validate`;
- to close it out, run `poc-graduate`.

Do not re-scaffold over an existing POC.

## Step 2 — Write the contract

This is the part that matters. Use `AskUserQuestion`, one topic at a time, and push back on
vague answers — a mushy contract is how a POC becomes a permanent unbudgeted project.

**The question.** One sentence, answerable yes or no. "Can we extract structured invoice
fields from scanned PDFs accurately enough to skip manual entry?" is a question. "Explore
document AI" is not. If the user gives you a topic instead of a question, offer two or three
candidate questions drawn from it and let them pick.

**The success signal.** What observation would make the answer "yes"? It must be something
you can point at afterwards — a measurement, a working path through the system, a demo that
either runs or does not. Prefer a number with a threshold. "It works well" is not a signal.

**The kill criteria.** Two to four conditions, each of which independently ends the POC as a
"no". Good ones are concrete and checkable:

- an accuracy, latency, or cost threshold that cannot be met;
- a required capability that turns out not to exist;
- an integration that cannot be made to work within the box;
- the time box expiring with the question unanswered.

Always include the time box as a kill criterion. A POC that cannot fail on the clock has no
clock.

**The time box.** A number of days or a calendar end date. Record both the start and the end.

**What is explicitly out of scope.** Name the production concerns this POC will not address
— hardening, scale, failover, access control, observability, migration. Writing them down is
what makes it legitimate to skip them, and what stops the POC being mistaken for a product.

**The stack.** The author's choice. Ask what language, libraries, frameworks, and local
infrastructure they intend to use, record the answer, and do not argue unless a choice
directly threatens the question being answered. There is no mandated framework here.

**The target runtime.** Where this would run *if it graduates*. Record the intended answer
now, while it is cheap, even if it is "undecided" — `poc-graduate` reads this field and a
decision made under deadline pressure later is a worse decision. Record it as a plain name;
no particular vendor or platform is assumed.

## Step 3 — Write `.poc/poc.json`

```bash
mkdir -p .poc
```

```json
{
  "poc_active": true,
  "name": "<poc-name>",
  "question": "<the one question>",
  "success_signal": "<the observation that answers yes>",
  "kill_criteria": [
    "<criterion 1>",
    "<criterion 2>",
    "Time box expires (<end date>) with the question unanswered"
  ],
  "time_box": { "started": "<YYYY-MM-DD>", "ends": "<YYYY-MM-DD>", "days": 0 },
  "out_of_scope": ["<concern>", "<concern>"],
  "stack": { "language": "<lang>", "key_dependencies": ["<dep>"], "local_infra": "<how it runs locally>" },
  "target_runtime": "<where this would run if it graduates, or 'undecided'>",
  "evidence": []
}
```

`evidence` starts empty and is appended to as the work produces measurements. Each entry:
`{ "date": "...", "criterion": "<which criterion or signal it bears on>", "observation": "...", "source": "<file, log, or command>" }`.

Tell the user plainly: **an empty `evidence` array at validation time means the POC answered
nothing**, regardless of how much code exists.

## Step 4 — Write the POC CLAUDE.md

At the POC root, so every session inherits the contract:

```markdown
# <poc-name> — proof of concept

**Question:** <the one question>
**Success signal:** <signal>
**Time box:** <start> → <end>

## Kill criteria

Any one of these ends the POC as a "no":
- <criterion>

## Out of scope

This is a proof of concept. It deliberately does not address: <list>.
Do not add them. If one of them turns out to be load-bearing for the question,
that is itself a finding — record it in `.poc/poc.json` evidence and raise it.

## Working rules

1. Every change must move the question toward an answer. If it does not, it is out of scope.
2. Record observations in `.poc/poc.json` evidence as they happen, with their source.
   Evidence reconstructed from memory at the end is not evidence.
3. Prefer the shortest path that produces a real measurement over the cleanest design.
4. Secrets stay out of the repo even here.

## Stack

<language, dependencies, how to run it locally>
```

## Step 5 — Scaffold the minimum

Create only what the chosen stack needs to run and produce a measurement:

```bash
mkdir -p src tests
```

Add the manifest or dependency file for the chosen language, a `.gitignore` appropriate to
it, and whatever local runtime definition the user named. Nothing else. No CI configuration,
no deployment definitions, no multi-service topology, no abstraction layers for a second
implementation that does not exist yet.

If the user asks for one of those, point at the out-of-scope list they just wrote.

Do not run git commands. Tell the user what to commit and let them commit it.

## Step 6 — Report

Print the contract back: question, success signal, kill criteria, time box end date, stack,
target runtime, and the files created. Then state the next step — build, record evidence as
you go, and run `poc-validate` before the time box expires, not after.

## Common failure modes

- **A question that cannot be answered "no."** Rewrite it until it can.
- **Kill criteria nobody could check.** If you cannot say what command or observation tests
  a criterion, it is decoration. Replace it.
- **Scope creep dressed as diligence.** Adding retries, config layers, or a second backend
  because "we'll need it in production" is how the time box is lost.
- **No evidence trail.** A POC that ends with an opinion rather than a record cannot
  graduate and cannot honestly be killed.
