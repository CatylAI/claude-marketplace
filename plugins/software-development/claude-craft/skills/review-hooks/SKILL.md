---
name: review-hooks
license: MIT
description: "Audit hook scripts and their settings registrations together. Fans out four lenses in parallel: model-invocation cost inside hooks, process-spawn and duplicated-work overhead across handlers on the same event, written rules that are being relied on by memory and should be mechanically enforced instead, and staleness — dead branches, missing lifecycle coverage, absent CLI fallbacks, and mismatched timeouts. Returns one ranked synthesis citing file and line. Recommendations only — it never edits. Use after changing hooks, when edits feel slow, when a hook fires on the wrong files, or as a periodic sweep. Not for auditing skills, agents, or permission layering on their own."
when_to_use: "audit my hooks, review hooks.json, hooks are slow, hook fires on the wrong files, should this rule be a hook, hook timeout, dead hook, hook settings review"
user-invocable: true
argument-hint: "[path to a hooks directory or settings file; defaults to the repo's .claude/ and ~/.claude/]"
allowed-tools: Read, Glob, Grep, WebFetch, Agent, Bash(bash:*), Bash(command:*)
context: fork
---

# Hook Audit — Four Lenses in Parallel

Audit a hook system end to end: the scripts, the settings block that wires them, and the written
rules they are supposed to be enforcing. Spawn four subagents in parallel (one message, four `Agent`
calls), then merge their findings into one ranked list.

Scope: the hook definitions in `.claude/settings.json`, `.claude/settings.local.json`, and any
`hooks.json` a plugin contributes; the scripts those entries point at; and the project's written
conventions (`CLAUDE.md` and anything it references).

## Shared context

Every agent reads, before starting:

- the settings hook block — which matcher runs which command, with which timeout;
- every hook script and its shared helpers;
- the project's written conventions, since many of them are candidates for enforcement;
- the current hook documentation, so the audit is against the real event surface and not a
  remembered one. Fetch it rather than recalling it.

Tell each agent the same thing: report discrete findings, each with a file and line, a severity, and
a concrete proposed change. No edits.

## Run the mechanical checks first

Three read-only scripts ship with this plugin, under `${CLAUDE_PLUGIN_ROOT}/scripts/hooks/`. Run
them before fanning out: they settle the mechanical questions deterministically, so the four lenses
spend their budget on judgement instead of re-deriving what a script already knows. They only read;
none of them edits anything.

They need `jq`. If it is missing, say so and continue with the lenses — do not let the audit fail
on a missing tool.

```bash
command -v jq >/dev/null 2>&1 || echo "jq missing — mechanical checks unavailable"

# 1. The registration. Walks hooks.json (wrapped or bare), checking event names, matcher
#    literal-vs-regex, hook type, command shape and timeouts. With --plugin-root it also
#    confirms every registered command resolves to a file that exists.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/validate-hook-registration.sh" \
  <path/to/hooks.json> --plugin-root <plugin-dir>

# 2. The sources. Static checks on the hook scripts themselves — fields read but never
#    obtained, machine-local paths, eval on hook input, missing CLI guards, blocks with no
#    reason on stderr. Language-aware: shell-only rules are not applied to other runtimes.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/lint-hook-source.sh" --dir <hooks/src-dir>

# 3. One hook, actually executed. Builds a realistic stdin payload for the named event,
#    exports CLAUDE_PLUGIN_ROOT / CLAUDE_PROJECT_DIR / CLAUDE_ENV_FILE, runs the hook under a
#    timeout, and reports the exit code with stdout (the decision channel) and stderr (the
#    feedback channel) kept apart. `--print-payload` shows the fixture without running anything.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-hook-event.sh" \
  --event PreToolUse --tool Bash -- <the hook command>
```

Each exits 0 when clean, 1 on findings, 2 when misconfigured. Feed their findings to the lenses as
established fact and let the agents reason about what to do, not about whether it is true.

Where this bites hardest: Lens 4 asks whether an entry points at a missing script and whether a
timeout matches its workload — `validate-hook-registration.sh --plugin-root` answers the first
mechanically. And the whole audit says "verify one deliberately rather than assuming";
`run-hook-event.sh` is how that verification is actually performed. Use it on at least one hook per
event the system registers, and quote the exit code in the finding.

## Lens 1 — Cost inside hooks

A hook that calls a model runs on every matching event, unattended, with nobody watching the bill.

First determine whether any hook calls a model at all: grep the hook sources for an SDK import or
an inference call. If none do, say so plainly and then check for *drift* — a leftover SDK
dependency in the manifest, documentation describing model-calling behaviour that no longer exists,
or a stale configuration key. Remove-the-reference findings are real findings.

For each hook that does call a model:

- which model, and is it pinned or inheriting a default?
- what bounds the work — turn ceiling, prompt size cap?
- what gates it — a minimum change threshold, a cooldown, a debounce?
- what does it fire on? A hook matching every write will run on lockfiles, generated output,
  and documentation. That is usually unintended.
- a rough per-invocation cost.

Recommend: pin to the cheapest model that can do the job, cut the prompt to what the decision
actually needs, and narrow the matcher before anything else.

## Lens 2 — Process and duplicated work

Every hook entry on an event is a separate process start. Several handlers on the same event each
pay interpreter startup, each re-resolve the repository root, and each re-read the same file from
disk.

- Map what each handler does on entry, and mark the work that is identical across handlers firing
  on the same event.
- Look for the same condition checked in two places with two different outcomes — a check that
  blocks in a pre-event handler and merely warns in the post-event one is one rule with two
  surfaces and two behaviours.
- Look for the same message emitted from two branches of one script.
- Evaluate consolidation into a single dispatcher against its complexity cost, and say which way it
  comes out. Consolidation is not automatically correct; a dispatcher that must know about every
  check is harder to change than five small scripts.

Propose a concrete plan: which files merge, what shared helper is needed, and the expected
reduction.

## Lens 3 — Written rules that should be mechanical

Read the project's conventions. Classify each rule:

- **(a) already enforced** — a hook or permission rule blocks or warns on it;
- **(b) should be enforced** — it is violated in practice because it depends on the model
  remembering it;
- **(c) judgement only** — no mechanical signal can decide it.

Prioritize category (b) by what actually goes wrong: destructive commands run without confirmation,
verification steps skipped, generated files edited by hand, credentials pasted into tracked files,
commit or branch conventions ignored, a prerequisite step bypassed.

For each (b) rule, sketch the hook: which event, which matcher, the exact condition to detect, the
exit behaviour, and the message the model will read. A rule whose violation cannot be detected from
the tool input is a (c), not a (b) — say so rather than proposing an unimplementable hook.

## Lens 4 — Staleness and drift

Cross-reference the implementation against the current hook API.

- Lifecycle events with no coverage that would help, and events being used where a cheaper one
  would do.
- Deprecated call shapes or outdated payload assumptions.
- Dead branches — conditions that cannot be reached given the matchers actually configured.
- Entries wired in settings that point at a missing script, or at a script that always exits zero
  without doing anything.
- External CLI dependencies invoked with no graceful path when the CLI is absent. A hook that
  fails because a tool is not installed blocks work for a reason unrelated to the work.
- Timeouts mismatched to the workload: too short produces silent failures that look like the hook
  passing, too long blocks every edit.
- Anything depending on the working directory being the repository root — that assumption breaks
  under worktrees and subdirectory invocations.

Severity each finding: **critical** (blocks work or silently fails open), **warning**, **minor**.

## Synthesis

One ranked output, under about 1,500 words. Every item cites a file and line and quotes the relevant
code or rule.

### Highest-value changes (top five)

Cost, reliability, or maintainability, with the estimated impact.

### Already correct (top five)

Name what is well done so it does not get "improved" later.

### Needs a decision (top three)

Genuine trade-offs. Present the options and the cost of each. Do not pick.
