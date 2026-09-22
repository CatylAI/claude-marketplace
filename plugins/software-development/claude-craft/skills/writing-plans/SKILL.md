---
name: writing-plans
license: MIT
description: "Turn an approved spec into an implementation plan that a worker with no context for this codebase can execute task by task. Each task names the exact files it creates, modifies and tests, declares the signatures it consumes from earlier tasks and produces for later ones, and carries real code and real commands in every step — no placeholders. The header pins the plan to its spec and reproduces the spec's project-wide constraints verbatim, so a single dispatched task carries them without reading the spec. Use after design-intake's architectural path, or whenever a spec or written requirements exist and the work is multi-step. Not for producing the design itself, which is design-intake; not for orchestrating the workers that run the plan, which is release-train."
when_to_use: "write an implementation plan, turn this spec into tasks, plan this out before we code, break this into tasks, I have requirements and need a plan, plan the rollout of this feature, task breakdown for the spec"
user-invocable: true
argument-hint: "[path to the spec, or the feature name]"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(date:*), Bash(ls:*), Bash(mkdir:*), Bash(git:*), AskUserQuestion
---

# Writing plans

Produce the document that stands between an approved spec and code someone writes.

**Write the plan assuming the engineer has zero context for this codebase and questionable taste.**
Assume a skilled developer who knows almost nothing about this toolset, this problem domain, or
good test design. Everything they need is in the plan: which files to touch, the code, the test,
the command that runs it, the expected output, the commit. If a step requires them to know
something, the plan is the place that tells them.

That framing is not pessimism about people. It is what makes the plan survivable when each task is
handed to a fresh session that genuinely has no history — which is the normal case once the plan is
executed by anything other than the session that wrote it.

## Preconditions

A plan argues from a spec. If there is no spec and no written requirements, stop and run
`design-intake` first — a plan written from a conversation is a plan whose authority evaporates the
moment two tasks disagree.

If the spec covers several independent subsystems, it should have been decomposed during intake. If
it was not, say so and propose one plan per subsystem. Each plan must produce working, testable
software on its own.

**One plan, one repository.** Paths in a plan are repository-relative and unqualified, so a plan
that spans repositories has file references that cannot be resolved without guessing which
checkout. A change landing across several repositories gets one spec and one plan per repository,
cross-referenced in each header.

## Where the plan goes

`docs/plans/YYYY-MM-DD-<feature-name>.md`. Get the date rather than assuming it:

```bash
date +%F
mkdir -p docs/plans
ls docs/plans
```

On a surface with no shell, ask for today's date and for the contents of `docs/plans/`, and wait.
Do not name the file from a guessed date — the date is how plans sort, and a wrong one puts this
plan in the middle of last month's work. An explicit repository convention for plan location
overrides this default.

## Map the files before you write tasks

Decomposition decisions get locked in here, not in the task list. Before defining a single task,
write down which files will be created or modified and what each is responsible for.

- Give each file one clear responsibility, with boundaries you can state.
- Prefer smaller, focused files. Edits are more reliable in a file that fits in context at once,
  and a file that has grown large is usually doing more than one thing.
- Files that change together live together. Split by responsibility, not by technical layer.
- In an existing codebase, follow the patterns that are there. Do not unilaterally restructure —
  but if a file this work modifies has already grown unwieldy, planning the split is reasonable.

This map is what the task boundaries are drawn on.

## Task right-sizing

**A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's
gate.**

Fold setup, configuration, scaffolding and documentation into the task whose deliverable needs
them — they are not tasks. Split only where a reviewer could meaningfully reject one task while
approving its neighbour. Every task ends with an independently testable deliverable.

That is a test, not a size heuristic. "About fifty lines" is not a rule; "a reviewer could approve
the parser and reject the serializer" is.

Within a task, each step is one action of two to five minutes: write the failing test, run it and
watch it fail, write the minimal implementation, run it and watch it pass, commit.

## The plan header

Every plan starts with this, and none of it is optional:

```markdown
# <Feature> implementation plan

> For agentic workers: `release-train` dispatches this plan task by task. Steps use checkbox
> (`- [ ]`) syntax so progress is visible in the file itself.

**Goal:** <one sentence: what this builds>
**Architecture:** <two or three sentences: the approach>
**Tech stack:** <the key technologies and versions>
**Spec:** <repository-relative path to the design document this plan implements>

## Global constraints

<The spec's project-wide requirements — version floors, dependency limits, naming and copy rules,
platform requirements, licence headers — one line each, with exact values copied verbatim from the
spec. Every task's requirements implicitly include this section.>
```

Three of those lines do specific work and are worth defending.

**`Spec:`** makes the spec the binding authority. The plan argues *from* the spec, so when two
tasks conflict mid-execution, the conflict is decidable: read the spec, rule, keep going. Without
the pointer, a mid-execution ruling is arbitrary, and arbitrary rulings are how a plan drifts away
from the thing it was supposed to build.

**`Global constraints`** is reproduced verbatim into the plan rather than referenced, because a
dispatched worker is given one task, not the plan and not the spec. A constraint that lives only in
the spec is a constraint every worker violates. Copy the exact values: `node >= 20`, not "a recent
Node"; `MIT`, not "our usual licence".

**The worker line** names who executes this. Change it if the plan will be run inline in one
session rather than dispatched; do not delete it, because a plan with no stated executor gets
executed by whoever opens it, in whatever way they prefer.

## The task template

````markdown
### Task N: <component>

**Files:**
- Create: `exact/path/to/new_file.ts`
- Modify: `exact/path/to/existing.ts:123-145`
- Test: `tests/exact/path/to/new_file.test.ts`

**Interfaces:**
- Consumes: `parseConfig(raw: string): Config` from Task 2
- Produces: `applyDefaults(c: Config, env: Env): Config` — returns a new object, never mutates

- [ ] **Step 1: write the failing test**

```ts
test("applyDefaults fills the retry count from env", () => {
  expect(applyDefaults({ retries: undefined }, { RETRIES: "3" }).retries).toBe(3);
});
```

- [ ] **Step 2: run it and confirm it fails**

Run: `npm test -- applyDefaults`
Expected: FAIL, "applyDefaults is not defined"

- [ ] **Step 3: write the minimal implementation**

```ts
export function applyDefaults(c: Config, env: Env): Config {
  return { ...c, retries: c.retries ?? Number(env.RETRIES) };
}
```

- [ ] **Step 4: run it and confirm it passes**

Run: `npm test -- applyDefaults`
Expected: PASS

- [ ] **Step 5: commit**

```bash
git add src/config/defaults.ts tests/config/defaults.test.ts
git commit -m "feat(config): apply env-derived defaults"
```
````

### Why `Interfaces` is there

A task's implementer sees only its own task. It cannot read Task 2 to find out what `parseConfig`
returns, and it will not ask — it will invent a plausible name and a plausible shape. The result is
code that compiles inside its own task and does not link up with its neighbours, and the failure
presents as implementer incompetence rather than as the plan defect it is.

`Consumes` and `Produces` carry exact signatures: real names, real parameter types, real return
types, and any contract the type does not express ("returns a new object, never mutates"). A prose
description of what a function does is not a signature and does not prevent this failure.

`Interfaces` is also what makes the dependency edges between tasks readable. A task that consumes
from Task 2 depends on Task 2, and that is the merge order.

## No placeholders

Every step contains the actual content the engineer needs. These are **plan failures**, not
shortcuts:

- "TBD", "TODO", "implement later", "fill in the details".
- "Add appropriate error handling", "add validation", "handle edge cases". Name the errors, name
  the validation, name the edges.
- "Write tests for the above", with no test code.
- **"Similar to Task N."** Repeat the code. Tasks are read out of order, and often by someone who
  never saw Task N.
- Steps that describe *what* without showing *how*. A code step needs a code block.
- References to a type, function or method that no task defines.

Each of these reads as reasonable while you are writing it, because you are holding the whole
design in mind. None of them survives contact with a reader who is not.

## Self-review

Run this yourself after the plan is complete. It is a checklist, not a subagent dispatch.

| Pass | Method | Fix |
| --- | --- | --- |
| Spec coverage | Walk each requirement in the spec. Point at the task that implements it. | List the gaps, then add the missing tasks. |
| Placeholder scan | Search the plan for every pattern above. | Write the real content. |
| Type consistency | Compare the names and signatures used in later tasks against those defined in earlier ones. | Reconcile. `clearLayers()` in Task 3 and `clearFullLayers()` in Task 7 is a bug, not a variation. |
| Path consistency | Compare the `Files:` blocks across all tasks. Does a task modify a file no task creates? Do two tasks create the same path? | Add the creating task, or merge the colliding tasks. |

Fix inline. Do not re-review — a second pass over your own fresh edits finds nothing and costs a
turn.

## The handoff to `release-train`

`release-train` runs a plan as parallel workers, and it admits work only on proof of disjointness:
"*The admission criterion is disjointness, not worker count. If you cannot demonstrate that the
bundles touch non-overlapping sets of files, you do not have parallel work.*" Its bundle definition
says what it needs from each unit of work:

> A **bundle** is the unit a worker owns. It carries a name, a repository root, an explicit list of
> owned path globs, acceptance criteria phrased as observable facts, and any `depends_on` edges to
> other bundles.

A task in this format supplies all four, from three different blocks:

| What `release-train` needs | Where it comes from |
| --- | --- |
| Name | The task heading |
| Repository root | The plan — one plan is one repository, by the rule above |
| Owned paths | `Files:` — exact paths, already expanded, so the `comm -12` intersection needs no glob expansion and no `:(glob)` care |
| Planned new paths | `Files: Create:` — this is precisely the case `release-train` flags, where `git ls-files` sees nothing because the file does not exist yet |
| Acceptance criteria as observable facts | The run-and-confirm steps: an exact command and its expected output |
| `depends_on` edges | `Interfaces: Consumes` — consuming from Task N is an edge to Task N |

**Disjointness is verified from `Files:`, not from `Interfaces:`.** `Interfaces` is about symbols;
the intersection `release-train` runs is over paths. Writing exact paths in every `Files:` block is
therefore what makes the plan dispatchable, and `Interfaces` is what makes the resulting code link
up and the merge order derivable. Both are required and they answer different questions.

The `Path consistency` self-review pass above is the cheap local version of the same intersection:
two tasks that `Create:` the same path, or `Modify:` a shared registry or barrel file, are the
overlap `release-train` would otherwise discover at merge time. Surface it in the plan — either
merge the tasks, or assign the shared file to exactly one task and have the others state the change
they need in their reports.

## Execution handoff

Once the plan is saved, say where it is and offer the choice explicitly rather than picking:

> "Plan saved to `docs/plans/<name>.md`. Two ways to run it: dispatched, with `release-train`
> supervising one worker per bundle in its own worktree; or inline, working the tasks in order in
> this session with a review checkpoint at each one. Which?"

Dispatched execution needs the disjointness proof `release-train` owns, so the plan's `Files:`
blocks have to be exact before it starts. Inline execution does not, but it also does not get the
fresh-reviewer gate at each task boundary — say that, rather than presenting them as equivalent.

## Rationalizations, and why each one is wrong

| What you will think | What is actually true |
| --- | --- |
| "The implementer can read the spec for the constraints." | It is given one task. `Global constraints` is reproduced verbatim because nothing else reaches the worker. |
| "Writing the actual test code in the plan is duplicating work." | It is the only thing that makes the step verifiable. A step saying "write a test" is a step with no definition of done. |
| "Task 7 is the same shape as Task 3, I'll just reference it." | Tasks are read in isolation and out of order. Repeat the code. |
| "I'll leave the exact paths until execution — they might change." | Then nothing can prove the tasks are disjoint, and the plan cannot be dispatched. Paths that change are an edit to the plan, not a reason to omit them. |
| "The signatures are obvious from the description." | They are obvious to you, holding the whole design. The implementer holds one task and will invent a name. |
| "Spec coverage is fine, I wrote both documents." | You wrote them at different times with different amounts of the design in mind. Walk the requirements. |

## Failure modes

**A plan with no `Spec:` line.** Every mid-execution conflict becomes a judgement call with no
authority to appeal to, and the rulings diverge.

**Constraints referenced rather than copied.** Every worker violates them, identically, and it is
caught at integration.

**Prose interfaces.** "Task 4 exposes a config loader." Task 6 writes `loadConfig`, Task 4 wrote
`readConfiguration`, and the branch does not build.

**Glob-shaped `Files:` entries.** `src/config/**` reads as precise and defeats the intersection
that would have caught the overlap. Write the paths.

**Tasks sized by line count.** A task too small to carry its own test cycle wastes a reviewer seat;
one too large hides a rejectable half inside an approvable whole.
