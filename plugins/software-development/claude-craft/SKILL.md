---
name: claude-craft
description: "Architecture reference and audit toolkit for building systems on the Claude Agent SDK and Messages API — loop control, coordinator/subagent design, tool interfaces, context economy, output contracts, deterministic enforcement, MCP integration, provenance and escalation, and skill/plugin authoring — plus runnable audits of your own skills, agents, hooks and settings, a debugging procedure, a session handoff writer, a codebase walkthrough, an orchestrated multi-worktree release runner, and a force-push-free worktree sync. Use when designing, reviewing, or debugging an agent system and you need the design rule rather than the API signature, when auditing a Claude Code configuration, or when running one change across several worktrees at once."
license: MIT
---

# claude-craft

A library for agent systems built on Claude, in two halves. The **design references** cover one
layer of the architecture each: the rules that hold at that layer and the failure modes that appear
when they are broken. The **audits and procedures** apply those rules to a repository you already
have — reviewing your own skills, agents, hooks and settings, debugging a defect, handing a session
off, or orienting in an unfamiliar codebase.

The references are not API documentation. Look up exact request and response shapes in the official
Claude API and Agent SDK docs; come here for the question of how the pieces should be arranged.

## Design references

| Skill | Covers |
| --- | --- |
| `agentic-loop-control` | Branching on `stop_reason`, appending tool results, managed vs. hand-rolled loops, turn and budget caps, retry policy, structured failure propagation. |
| `agent-orchestration` | When delegation pays for itself, hub-and-spoke routing, decomposition and coverage, subagent descriptions, context passing across isolated windows, session resume vs. fork vs. fresh. |
| `tool-interface-design` | Tool boundaries, naming, schemas, description budget, response shaping, error text the model can act on. |
| `context-economy` | Prompt caching, prefix stability, compaction, what belongs in the window vs. on disk, measuring cost per task. |
| `output-contracts` | Structured output, schema design, validation at the boundary, partial and null results, versioning a contract. |
| `deterministic-enforcement` | Moving invariants out of the prompt into code: hooks, permission gates, validators, CI. |
| `mcp-integration` | When to reach for MCP, transport choice, server scoping, tool namespacing, auth, and the cost of a large server surface. |
| `provenance-and-escalation` | Carrying source metadata through the pipeline, confidence, and routing to a human instead of guessing. |
| `skill-and-plugin-authoring` | Writing skills that get selected and followed: frontmatter, description as the trigger, progressive disclosure, plugin packaging. |

## Audits and procedures

| Skill | Covers |
| --- | --- |
| `review-skills` | Audits a tree of `SKILL.md` files: skill-versus-agent classification, forked context justification, invocability flags, description quality, merge candidates. |
| `review-agents` | Audits an agent roster: packaging verdict, enumerated rules that should become three worked examples, descriptions as routing signals. |
| `review-hooks` | Audits hook scripts with their settings registrations across four lenses: model-call cost, process overhead, written rules that should be mechanical, and staleness. |
| `claude-config-audit` | Interactive end-to-end audit of one repository's configuration: mechanism placement, enforcement strength, scope cost, hierarchy contradictions. Writes only what you approve. |
| `config-audit` | Whole-configuration sweep: runs the three audits above in parallel, adds a settings and permissions layering pass, and reports the cross-cutting findings none of them can see alone. |
| `agent-sdk-review` | Surveys a codebase that uses the Agent SDK and reports deviations from the design references, ranked by blast radius. |
| `debug` | Runs a debugging session: symptom interview, delegated read-only root-cause analysis, then fix and verification in the main thread. |
| `handoff` | Writes a self-contained handoff another engineer or a fresh session can resume from, including what was already ruled out. |
| `repo-walkthrough` | Guided tour of an unfamiliar codebase: structure map, named patterns with their failing alternatives, one traced flow, and what a newcomer will break. |
| `release-train` | Runs a large change as an orchestrated release: one leader supervising named workers, each in its own git worktree, converging on a shared release branch. Owns bundle disjointness, verification and merge order. |
| `session-sync` | Brings every worktree of a repository current with its base branch without force-pushing, choosing the safe route per branch from that branch's published state. |
| `design-intake` | Classifies a request as spike, bounded or architectural, then runs the matching process. The ceremony scales with the task; the approval gate before implementation never does. |
| `writing-plans` | Turns an approved design into an executable plan: a spec pointer, a verbatim constraints block, and per-task `Files` and `Interfaces` blocks that `release-train` reads to prove bundles disjoint. |


## Tooling

The audit skills above judge; these run. Both are Claude Code only — they need a shell.

| Path | What it does |
| --- | --- |
| `scripts/eval/` | Measures whether a skill actually fires. Drives real `claude -p` sessions against an eval set and reports a trigger **rate**, optimises a description against a **held-out** split so it is not tuned onto the queries you wrote, and aggregates with-skill against without-skill. Every entry point prints the session count before spending anything and supports `--dry-run`. |
| `scripts/hooks/` | Runs a hook against a synthetic event for its type, lints hook source, and validates a `hooks.json` registration. Calibrated against `dev-guardrails`, which is the most mature hook package here: anything these report against it is a bug in the tooling. |

A measurement that could not run is never reported as a zero. `scripts/eval` exits 3 and emits a
null rate when `claude` is unreachable, because a 0% that means "the skill never fired" and a 0%
that means "nothing ran" are different answers.

## Agents

| Agent | Role |
| --- | --- |
| `debugger` | Read-only root-cause analysis. Tests falsifiable hypotheses against observed evidence and returns a diagnosis with a fix direction. Never edits. Paired with the `debug` skill. |
| `agent-sdk-validator` | Completion gate on a change touching Agent SDK code. Returns PASS, DRIFT, SKIP, or NO VERDICT with findings ranked by blast radius. |
| `adr-currency-validator` | Completion gate on whether Architecture Decision Records and their index are in sync with a change. |

## Reading order

Start with `agentic-loop-control` — a loop that mis-detects completion invalidates everything
above it. Then `tool-interface-design` and `output-contracts` for the agent's interfaces, then
`agent-orchestration` and `context-economy` once you are running more than one agent.

The two workflow runners stand apart from the audits. `release-train` is the procedural
counterpart to `agent-orchestration` — read the design skill first, since the release runner
assumes its doctrine rather than restating it. `session-sync` is the cleanup that a multi-worktree
run leaves behind, and is useful on its own whenever feature branches have drifted.

For the audits, start with `config-audit` if you want the whole picture and do not yet know where
the problems are; go straight to `review-skills`, `review-agents`, or `review-hooks` when you
already do. `claude-config-audit` is the one that fixes things rather than only reporting.

## Conventions used here

Several skills recommend payload fields (`status`, `errorCategory`, `isRetryable`, provenance
blocks) that are conventions this library suggests, not platform features. Where that is the
case the skill says so. Adopt them consistently or not at all, and do not describe them to your
team as part of the API.
