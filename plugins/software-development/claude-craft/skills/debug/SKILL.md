---
name: debug
license: MIT
description: "Run a debugging session end to end in the main thread: interview for symptoms, delegate read-only root-cause analysis to the debugger agent, then apply and verify the fix here where the full test output is visible. Keeps the hypothesis-fix-retest loop in the main thread because each step depends on the last, and offloads only the focused investigation. Use when investigating a bug, a crash, a failing test, or behaviour nobody can explain. Not for a code-quality review with no defect, and not for a production observability question that needs live telemetry."
when_to_use: "debug this, why is this failing, this test fails, unexpected behaviour, crash, find the root cause, it worked yesterday"
user-invocable: true
disable-model-invocation: true
argument-hint: "[bug description, error message, or failing test]"
allowed-tools: Read, Edit, Bash, Grep, Glob, Agent, AskUserQuestion
---

# Debug

Owns a complete debugging session in the **main thread**. The fix-and-verify loop stays here: each
fix depends on the previous observation, and whoever applies it needs unfiltered test output to
react to. Only the read-only investigation is delegated.

## Why the loop stays in the main thread

Debugging is iterative — hypothesis, fix, retest, new observation — and the value of each step is
the raw output of the last. A subagent returns a summary, which is exactly the wrong shape for a
loop that runs on details. So the `debugger` agent is scoped to the one part that *is* summarizable:
a focused read-only investigation whose only useful output is the diagnosis. This skill orchestrates
around it.

## Step 1 — Gather symptoms

You are interviewing a reporter. Collect what is missing from the user's message:

- **Expected** — what should happen.
- **Actual** — what happens instead.
- **Errors** — the exact text, and the full stack trace if there is one. Not a paraphrase.
- **Started** — when it broke, or whether it ever worked.
- **Reproduction** — the command or steps that trigger it, and whether they trigger it every time.

Ask about *experience*, never about cause, file, or fix — that is the investigation's job, and a
reporter's theory is the single most common source of anchoring. Use `AskUserQuestion` when several
facts are missing at once.

Intermittent reproduction is itself a finding. Note it explicitly; it changes which hypotheses are
plausible.

## Step 2 — Delegate the root-cause analysis

Spawn the `debugger` agent with the symptoms prefilled. It is read-only and returns a diagnosis; it
does not edit.

```
Agent(
  subagent_type: "debugger",
  description: "Root-cause <short slug>",
  prompt: "Investigate this bug and return a root-cause diagnosis. Do NOT fix.

  Expected: ...
  Actual: ...
  Errors: ...
  Started: ...
  Reproduction: ...

  Return ROOT CAUSE FOUND — with evidence, the files involved, a suggested fix direction, and a
  concrete verification step — or INVESTIGATION INCONCLUSIVE."
)
```

Handle the two non-diagnosis returns:

- **CHECKPOINT** — the investigation needs a mutation to reproduce, or a decision only you can
  make. Perform the action or ask the user, then re-delegate with the new information. If the
  remaining work is small, finish it here instead of paying for another round trip.
- **INCONCLUSIVE** — either investigate the top-ranked remaining possibility yourself, or report
  the ranked possibilities to the user and ask which to pursue. Do not re-spawn the same
  investigation hoping for a different answer.

## Step 3 — Apply the fix

With a root cause in hand:

1. Read the cited files completely. The agent named them; confirm the mechanism yourself before
   editing. A diagnosis you cannot re-derive is a diagnosis you cannot verify.
2. Make the **smallest** change that addresses the root cause. Adjacent improvements you noticed
   are a separate change; bundling them makes the verification ambiguous.
3. Follow the repository's conventions for the files you touch.

If the fix you are about to write treats a symptom rather than the mechanism, stop and say so.
Shipping a symptom patch is sometimes correct, but only deliberately and only labelled as one.

## Step 4 — Verify with full output

1. Run the exact reproduction the diagnosis named. Read the **whole** output, not the last line.
2. Confirm the original symptom is gone **and** that you can explain why the change removes it. A
   symptom that disappeared for an unexplained reason has not been fixed.
3. Run the surrounding tests for regressions.
4. If verification fails, you have a fresh observation — form a new hypothesis and iterate here, or
   re-delegate if the picture changed enough to be worth a clean investigation. Never stack a
   second fix on a mental model you can no longer explain.

Done means: the symptom no longer occurs, you understand the mechanism, related functionality still
passes, and it is stable across repeated runs — not "it worked once".

## Step 5 — Summarize

Report the root cause, the fix (files and what changed), and how it was verified. Note anything
ruled out along the way; that is the part a future session cannot rediscover cheaply. Do not commit
unless asked.
