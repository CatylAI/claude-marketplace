---
name: phase-execution
license: MIT
description: A four-phase execution loop — discover, analyze, act, verify — with checkpoints between phases, a success-criteria checklist and a progress-reporting format. Use when a task is large enough that it needs to be broken into stages, when work must survive an interruption, or when reporting progress on a long-running job.
---

# Phase Execution

Multi-step work fails in a characteristic way: the agent starts changing files before it
knows the shape of the problem, then cannot tell whether it is done. Splitting the work
into four phases with a checkpoint between each is what prevents that. The phases are
ordered by commitment — each one is cheaper to abandon than the next.

## The four phases

### 1. Discover — gather, change nothing

- Establish scope: which files, which components, which inputs.
- Read the project's own standards first (see `standards-first`).
- Detect the project type and the patterns already in use.
- Produce an explicit list of what is in scope and what is deliberately out.

Discovery is read-only. If you are editing during discovery, you skipped it.

### 2. Analyze — decide, still change nothing

- Compare current state against the requirement. Name each gap.
- Identify dependencies and ordering constraints between the changes.
- Surface conflicts: two requirements that cannot both hold, a convention the change would
  violate, an assumption that the code contradicts.
- Flag every decision that needs a human. Do not resolve an ambiguity by guessing and
  moving on — that is the cheapest failure to catch here and the most expensive later.

### 3. Act — change, in dependency order

- One logical change at a time. A commit-sized unit, not a session-sized one.
- Validate each change before starting the next: the build still builds, the file still
  parses, the test that covers it still passes.
- Record the rationale for non-obvious decisions as you make them, not from memory
  afterwards.
- If a change turns out to need something discovery missed, go back to phase 1 for that
  piece rather than improvising forward.

### 4. Verify — prove it

- Run every relevant check: lint, typecheck, test, build. All of them, not a subset.
- Confirm each requirement from phase 2 is actually met, by name.
- Check for regressions in code you did not intend to touch.
- Walk the success criteria below and mark each one honestly.

Verification is not "I made the change I described". It is evidence. See
`zero-tolerance-testing`.

## Checkpoints

Write a checkpoint at each phase boundary and before any irreversible step. A checkpoint is
what lets the work resume after an interruption, a context compaction or a handoff to
someone else.

```markdown
## Checkpoint: {phase name}

**Status:** completed | failed | in_progress
**Done:**
- {action}
**Next:**
- {step}
**Context needed to resume:**
- {the detail that would be lost if this session ended now}
```

For the file format and directory conventions of persisted state, see `state-tracking`.

## Success criteria

Before declaring work complete, every box must be genuinely ticked:

```markdown
- [ ] The governing standard was located and read
- [ ] Every file in scope was processed (and the out-of-scope list is still accurate)
- [ ] Each change was validated before the next one started
- [ ] All checks pass — none skipped, none suppressed
- [ ] No regressions outside the intended change
- [ ] Edge cases identified in analysis were handled or explicitly deferred
- [ ] Output follows the project's conventions
```

A criterion you cannot verify is not met. Say so rather than ticking it.

## Progress reporting

```
Phase {n}/{total}: {name}
- Completed: {what is done}
- Remaining: {what is left}
- Blockers: {what is stopping progress, or "none"}
```

Report blockers the moment they appear, not at the end. A blocker held until the final
summary has already cost the time it would have taken to unblock.
