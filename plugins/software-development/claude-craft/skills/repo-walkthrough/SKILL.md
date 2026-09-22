---
name: repo-walkthrough
license: MIT
description: "Guided tour of an unfamiliar codebase that leaves you able to contribute safely. Builds a hypothesis from the manifests, maps the structure, names the architectural patterns actually in use and explains each with a structural analogy and the naive alternative that fails, traces one end-to-end data flow, and calls out what a newcomer is most likely to break. Read-only; it explains, it does not change anything. Use when joining a project, reviewing an unfamiliar repository, or orienting before a first change. Not for auditing a Claude Code configuration, and not for reviewing a specific diff."
when_to_use: "walk me through this repo, explain this codebase, I am new to this project, how does this system work, where do I start, orient me in this repository"
user-invocable: true
argument-hint: "[repository path; defaults to the current directory]"
allowed-tools: Read, Glob, Grep, Bash(find:*), Bash(git:*), Bash(wc:*)
context: fork
---

# Repository Walkthrough

A guided tour of a codebase. The reader should finish knowing what the system does, why it is
built the way it is, and what they must not get wrong in their first change.

Apply the teaching method at the end of this file throughout — it is the point of the skill, not an
appendix.

## Step 1 — Orient before reading source

Read the root listing, the README, and the manifests: package descriptors, lock files, build files,
CI configuration, container definitions. Do not open source files yet. Form a hypothesis first, so
that reading the source either confirms or corrects something rather than accumulating unattached
detail.

Establish:

- what the system does, in one sentence;
- language, runtime, framework;
- the entry point;
- external dependencies — databases, queues, third-party APIs, cloud services;
- the shape: library, service, CLI, or monorepo.

State the hypothesis out loud: "From the manifests this looks like a *type* that *does X*. I will
confirm as we go." Then say, later, where it turned out to be wrong. That correction is worth more
to the reader than getting it right the first time.

## Step 2 — Map the structure

Walk the tree without reading contents. Identify:

- where the business logic lives;
- where the entry points are — request handlers, job handlers, CLI commands, workers;
- where the data models and schemas live;
- where the tests are, and how they relate to the source layout;
- any directory that does not fit the conventional layout for this stack. Those are where the
  project's real decisions usually hide.

Produce a **structure map**: a short annotated tree, one line per top-level entry, with a note on
anything non-obvious.

## Step 3 — Name the patterns

This is the core of the walkthrough. Read the significant source files and identify every
architectural or design pattern actually in use. For each:

**Name it precisely.** Not "there is some abstraction here" but "this is a repository pattern",
"this is a circuit breaker", "this is a strategy pattern for pluggable authentication".

**Give a structural analogy.** The analogy must map parts to parts — which piece of the familiar
thing corresponds to which piece of the code. Then say where the analogy breaks down, because it
will.

**Say what it is for.** What problem does it solve here? What would be worse without it?

**Show the contrast.** Sketch the naive approach a newcomer would reach for, and explain exactly
why it fails in this codebase. The failure explanation is where the understanding lives.

Patterns worth looking for — identify what is actually present, not this list:

- dependency injection versus hardcoded construction;
- data access abstraction;
- middleware chains and decorator stacks;
- event-driven versus request-response;
- configuration and secret handling;
- error strategy: exceptions, result types, or error codes;
- resilience: retry, backoff, circuit breaking, idempotency;
- where authentication and authorization are enforced;
- test strategy and mocking approach;
- build and deployment shape.

## Step 4 — Trace one flow end to end

Pick the most important operation the system performs — a request arriving, a message being
consumed, a command running. Trace it:

- where it enters;
- what validates it;
- what transforms it;
- what side effects it produces, and in what order;
- where it exits or responds.

Use a numbered flow, not prose. Annotate every step where something non-obvious happens, and say
what happens on the failure path at each step — most codebases are far less interesting on the
happy path than on the error path.

## Step 5 — What a newcomer must not get wrong

Name the three to five things most likely to cause a bad first change:

- invariants nothing enforces but everything assumes;
- code that looks wrong and is correct for a non-obvious reason;
- the obvious refactor that breaks something subtle;
- external contracts — API shapes, event schemas, migrations — with consumers outside this repo;
- testing gaps: areas that look covered but have important uncovered paths.

For each: the mistake, what breaks, and what to do instead.

## Step 6 — Mental model

Close with something readable in two minutes: what the system does, the three or four patterns that
matter and why they are there, what to understand before changing anything, and the first files to
read for depth.

---

## Teaching method

Lead with the mental model, not the implementation. Give the reader a frame they already hold
before showing detail. Name the pattern, then show this code as an instance of it.

- Never only describe what code does. Explain why it was written that way and what breaks without
  it.
- For every design choice, ask aloud what the naive version would look like and why it fails here.
- Use real names and real numbers from the codebase in analogies. A generic analogy is forgotten
  immediately.
- When something is genuinely clever or surprising, flag it: "this is counterintuitive — here is
  why it is correct."
- When something is wrong — technical debt, an anti-pattern, a decision that has aged badly — say
  so directly, with reasoning. Do not protect the existing code from critique.

**Analogy bar.** A good analogy maps the *structure* of the problem, not its surface. Weak: "it is
like a box that holds things." Strong: "it is like a bouncer at a door — it does not care what you
want inside, only whether you are on the list; the policy is separate from the enforcement, so you
change the guest list without retraining the bouncer." Then: "this holds for X, but breaks for Y,
where the real system does Z instead."

**Showing wrong.** Make the wrong version plausible — something a competent person would write.
Give the concrete failure case ("this breaks when two requests arrive in the same millisecond", not
"this could cause issues"). Name the root cause as a violated invariant.

**Depth.** Match depth to where the reader is most likely to hold a wrong model. Do not
over-explain what they already know; spend the words on what will surprise them.
