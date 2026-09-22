---
name: design-intake
license: MIT
description: "Classify an incoming build request before any code exists — spike, bounded, or architectural — say the classification out loud, run the matching amount of design, and stop at an explicit approval gate. Ceremony scales with the task; the gate never does. The architectural path ends in a written spec under docs/specs/ and hands off to writing-plans. Use when a request starts with build, add, create, implement, I want, let's, or can we, and no design exists yet. Not for diagnosing a defect, which is debug; not for framing a time-boxed experiment with kill criteria, which is project-scaffold's poc-start; not for recording a decision already taken, which is project-scaffold's adr-init."
when_to_use: "build X, add a feature, create a component, implement this, I want to, let's make, can we support, new service, new subsystem, redesign this, how should we structure this, design it before we code, turn this idea into a spec"
user-invocable: true
argument-hint: "[what you want to build]"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(ls:*), Bash(find:*), Bash(test:*), Bash(date:*), Bash(mkdir:*), AskUserQuestion
---

# Design intake

Turn a request into a design, and a design into an approved intent, before anything is built.

This sits in front of every other skill that writes code. Its only job is to decide how much design
the request needs, do that much, and refuse to start implementing until a human has said yes.

## The gate

**No implementation skill, no code, no scaffolding, no file layout, no dependency added, until you
have stated what you intend to build and the human has approved it.** This holds on every path
below, for every task, without exception.

The artifact scales with the task. A trivial change earns a two-sentence design in chat; a new
subsystem earns a written spec. The approval gate does not scale with anything. Two sentences still
have to be presented, and you still have to stop and wait.

That asymmetry is the whole skill. Everything below is machinery for deciding how much design to
write; none of it is machinery for deciding whether to ask.

## Classify first, and say the classification out loud

Before the first clarifying question, pick a path and announce it, with the reason, in one sentence:

> "This looks bounded — the retry logic already lives in `client/fetch.ts`, so I'll present a short
> design here rather than write a spec."

Announcing it is what lets the human override it. A classification you made silently is a decision
they never got to see.

### Spike

A feasibility question whose output is an answer, not code anyone keeps. "Can we…", "is it
possible…", "would this library work", "quick and dirty is fine".

Present the question and the probe in two or three sentences. Get a nod. Find out as cheaply as
correctness allows. Report a recommendation. Anything you built stays labelled throwaway, and
keeping it is a **new request** that gets its own classification.

No spec, no plan document.

If the request also asks for a time box, a falsifiable success signal, and kill criteria, that is
not a spike in this sense — it is a proof of concept, and `project-scaffold`'s `poc-start` owns it.
Hand it over rather than half-framing it here.

### Bounded

A well-scoped change to a flow **that already exists in this repository**: a new flag, one more
endpoint on an existing router, a one-file fix, a field added to a schema that is already there.

The disqualifier is cheap and it is not about you. **Bounded measures the repository, not your
familiarity with the problem.** If there is no existing flow you can open and read and change, the
task is not bounded, however well you understand this kind of system. A new project has no existing
flow, so a new project is never bounded.

Procedure: clarifying questions that matter → a short design in chat (approach, files touched, how
it will be tested) → **stop and wait for an explicit yes** → implement through the normal
development workflow. No spec file, no plan document.

Presenting the design and starting in the same message is skipping the gate. The gate is the
approval, not the design's length.

### Architectural

New projects, new subsystems, changes that restructure how components fit together, or changes that
alter an interface something else depends on.

Full process: context → questions → approaches → sectioned design → written spec → spec self-review
→ human review of the written spec → `writing-plans`.

## The ratchet is one-way

When in doubt between two paths, take the heavier one.

Hidden complexity discovered mid-task **upgrades** the path. Stop, say what you found, re-classify,
and re-present. Nothing downgrades mid-task — a task that turned out easier than expected still
carries the approval it was given, and finishing early is not a reason to skip a gate you already
passed.

Each task gets its own classification and its own approval. Approving a spike does not approve
building the thing the spike proved possible. Approving a bounded change does not approve the
follow-up it revealed.

## The architectural path

Create a todo per item and work them in order.

**1 — Explore the project context.** Run these and work from the output:

```bash
git log --oneline -10
git status -sb
ls
find . -maxdepth 2 -name 'README*' -o -maxdepth 2 -name 'CLAUDE.md'
test -d docs/adr && ls docs/adr
test -d docs/specs && ls docs/specs
```

They give, in order: what has been happening, what is uncommitted, the top-level layout, the files
that state this repository's conventions, and whether decisions and specs are already recorded
here. If you are on a surface with no shell, ask the human to paste the output and wait for it. Do
not classify or design from a guess about the repository — a confident design for a codebase you
never read is the failure this step exists to prevent.

**2 — Scope decomposition, before the detailed questions.** If the request describes several
independent subsystems — "a platform with chat, file storage, billing and analytics" — flag it now.
Do not spend clarifying questions refining the details of a project that has to be split first.

Help decompose into sub-projects: name the independent pieces, say how they relate, propose a build
order. Then take the first sub-project through this path. **Each sub-project gets its own spec, its
own plan, and its own implementation cycle.** One spec covering four subsystems produces one plan
nobody can execute.

**3 — Ask clarifying questions, one per message.** Prefer multiple choice; open-ended is fine when
the answer space is not enumerable. One question per message — if a topic needs more exploration,
that is several messages, not one message with several questions. Aim at purpose, constraints, and
what would count as success.

**4 — Propose two or three approaches with trade-offs.** Lead with your recommendation and say why.
Apply YAGNI to every one of them before presenting — the approach you recommend should already have
had its speculative features removed, not carry them as options.

**5 — Present the design in sections, scaled to their complexity.** A few sentences where it is
straightforward, up to two or three hundred words where it is genuinely nuanced. Cover
architecture, components, data flow, error handling, and testing. Ask after each section whether it
looks right, and be willing to go back.

Design for isolation: break the system into units with one clear purpose each, communicating
through interfaces you can state. For each unit you should be able to say what it does, how it is
used, and what it depends on. If someone cannot understand what a unit does without reading its
internals, or you cannot change the internals without breaking consumers, the boundaries are wrong.

In an existing codebase, follow the patterns that are already there. Where existing code genuinely
obstructs the work — a file that has grown past holding in context, a tangled responsibility the
change has to cross — include the targeted improvement in the design. Do not propose unrelated
refactoring.

**6 — Write the spec.** `docs/specs/YYYY-MM-DD-<topic>.md`. Get the date from `date +%F` rather
than assuming it; create the directory with `mkdir -p docs/specs` if it does not exist. An explicit
repository convention for spec location overrides this default — if `docs/design/` already holds
specs here, use it and say so.

**7 — Spec self-review.** Inline, by you, no subagent. Four passes, in order:

| Pass | What you are looking for | Fix |
| --- | --- | --- |
| Placeholders | "TBD", "TODO", empty sections, requirements phrased as intentions | Write the actual content |
| Internal consistency | Sections that contradict; an architecture that does not match the feature descriptions | Reconcile them, and say which one was wrong |
| Scope | Is this focused enough to produce one plan? | If not, go back to step 2 and decompose |
| Ambiguity | Any requirement that could be read two ways | Pick one reading and make it explicit |

Fix inline. Do not re-review — a second pass over your own fresh edits finds nothing and costs a
turn.

**8 — Human review of the written spec.** Say where it is and stop:

> "Spec written to `docs/specs/<name>.md`. Please read it and tell me what to change before I write
> the implementation plan."

Wait. If they ask for changes, make them and re-run step 7. Only proceed once they approve.

**9 — Hand off to `writing-plans`.** And to nothing else.

## Specs and ADRs are different records — do not duplicate one into the other

A **spec** describes one piece of work: what is being built, how it fits together, what counts as
done. An **ADR** records one decision that had real alternatives: what was chosen, what forced the
choice, and what it costs. `project-scaffold`'s `adr-init` owns the ADR convention in this
ecosystem — `docs/adr/NNN-kebab-title.md`, zero-padded and sequential, indexed in
`docs/adr/README.md`, with `Context` / `Decision` / `Consequences`.

The seam, stated so neither record grows a copy of the other:

- **Before designing, read the ADRs that bear on the area.** Step 1 lists `docs/adr/`. If an ADR
  already settles a question your design is about to re-open, you are not designing, you are
  re-litigating — say so and get that acknowledged before continuing.
- **A design that reverses a recorded decision amends that ADR in the same change.** That is the
  repository rule `adr-init` installs, and a spec is not an exemption from it. Never leave an ADR
  describing a decision the new design has replaced.
- **A design that makes a new architectural decision produces an ADR, and the spec links to it.**
  Number it continuing from the existing files, never renumbering; `Status: Proposed` while the
  work is unbuilt, `Accepted` once it lands. The spec then says "storage engine: PostgreSQL, see
  ADR-007" and does not restate the alternatives or the rationale. One decision, one home.
- **If the repository has no `docs/adr/`, the spec carries the rationale inline.** Do not create
  `docs/adr/` as a side effect of a design — adopting ADRs is its own decision with its own survey,
  and `adr-init` is what does it. Mention it as an option and move on.

The test for whether something belongs in an ADR rather than the spec: could this choice outlive
the feature that occasioned it, and would a future engineer ask "why is it like this"? If yes, it
is a decision. If it is only true of this feature, it is spec content.

## Terminal states are path-bound

| Path | Terminal state | What you may invoke next |
| --- | --- | --- |
| Spike | A reported recommendation, with anything built labelled throwaway | Nothing. Keeping the code is a new request — re-classify it. |
| Bounded | An approved short design | The normal development workflow. No plan document. |
| Architectural | A spec the human has read and approved | **`writing-plans`, and nothing else.** |

That last row is the rule that stops a design phase leaking straight into code. After architectural
intake, the next skill is `writing-plans` — never a frontend skill, never a scaffolding skill,
never an implementation skill, however obvious the first file looks.

## Rationalizations, and why each one is wrong

| What you will think | What is actually true |
| --- | --- |
| "This is too simple to need a design." | Simple means a *short* design, not no design. Two sentences in chat, then approval. |
| "I'll call it bounded and skip the spec." | Reaching for a label in order to skip work *is* the doubt. The ratchet says take the heavier path. |
| "It's bounded and the design is obvious — I'll start while they read it." | The gate is the approval, not the design's length. Present, then stop, until you hear yes. |
| "I understand this kind of app, so it's bounded." | Bounded measures the repository, not your familiarity. No existing flow to read and change means not bounded. A new project is architectural. |
| "The spike works, so I'll keep the code." | A spike's output is an answer. Keeping the code is a new request with its own classification and its own approval. |
| "It grew, but I'm almost done — no need to re-classify." | Hidden complexity upgrades the path mid-task. Being nearly finished on the wrong path is not a reason to stay on it. |
| "They approved the spike, so the follow-up is approved." | Each task gets its own classification and its own approval. |
| "They said 'sounds good' to my question, so that's the design approved." | Approval is to a stated intent, not to a conversation. If you cannot quote what they approved, they have not approved it. |

## When this skill is the wrong one

| Request | Skill that owns it |
| --- | --- |
| "Why is this failing", a crash, a failing test, behaviour nobody can explain | `debug` |
| "Is this feasible" *with* a time box, a success signal and kill criteria | `project-scaffold`'s `poc-start` |
| "Write down why we chose Postgres" — a decision already taken | `project-scaffold`'s `adr-init` |
| An approved spec that needs turning into executable tasks | `writing-plans` |
| A plan that needs running across several workers | `release-train` |

A classifier that fires on a debugging request is worse than no classifier: it turns "the build
broke" into a design conversation while the build is still broken. If the request names a symptom
rather than a desired capability, hand it to `debug` and stop.

## Worked examples

<example>
Request: "Add a `--dry-run` flag to the sync command."

Correct: announce bounded — `cli/sync.ts` exists and is the flow being changed. Ask the one
question that matters (does dry-run print the plan, or exit non-zero on drift?). Present four
sentences: the flag, the file, the branch it short-circuits, the test. Stop. Implement on yes.
</example>

<example>
Request: "Build us an internal billing platform."

Correct: do not start asking about invoice formats. Announce architectural, then decompose first —
metering, rating, invoicing, payment capture, reporting are five sub-projects with five specs.
Propose an order, take the first one through the path.
</example>

<example>
Request: "Can we use SQLite for the local cache instead of the JSON file?"

Correct: announce spike. "The question is whether SQLite's write concurrency holds under the CLI's
parallel workers. I'll write a throwaway harness that runs eight writers against both and reports
the failure rate. Sound right?" Then measure and recommend. If the answer is yes and they want it
built, that is a new request — re-classify it, probably as bounded.
</example>

<example>
Halfway through a bounded change, the "one more endpoint" turns out to need a new auth scope, which
needs a change to the token issuer that three other services read.

Correct: stop. "This has crossed into architectural — it changes an interface other services depend
on. I'm re-classifying and going back to the design step." Wrong: finish it, because it is nearly
done and the remaining work is small.
</example>

## Failure modes

**Classifying silently.** The classification is the human's decision to override, and one they
never saw is one they could not.

**Designing from an unread repository.** Step 1 exists because a design that assumes the wrong
structure produces a spec that is internally consistent and entirely wrong.

**The approval that was never asked for.** Presenting a design and continuing in the same message.
It reads like collaboration and is indistinguishable, afterwards, from not having asked.

**A spec that re-states an ADR.** Two records of one decision drift, and the one that drifts is
never the one anybody reads.

**A spec covering four subsystems.** It survives review, because each part is individually
reasonable, and then produces a plan whose tasks cannot be ordered.
