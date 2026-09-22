# claude-craft

Architecture guidance for building systems on the Claude Agent SDK and the Messages API, plus
the audit skills that check an existing Claude Code configuration against it.

Two halves. The **design** skills answer questions — how should the loop terminate, when does
delegation pay for itself, what belongs in a tool's schema, where should an invariant be
enforced — rather than restating API signatures. The **audit** skills turn those same rules on
a repository you already have and report where it drifted.

## Design skills

| Skill | Use it when |
| --- | --- |
| `agentic-loop-control` | Writing or reviewing a Messages API loop, or debugging an agent that stops early, loops forever, or swallows tool failures. |
| `agent-orchestration` | Building or reviewing a coordinator/subagent workflow, or diagnosing coverage gaps and uneven analysis depth. |
| `tool-interface-design` | Defining the tools an agent gets, or the model is calling the wrong tool, calling it repeatedly, or drowning in its output. |
| `context-economy` | Cost or latency per task is too high, prompt caching is not hitting, or long sessions degrade. |
| `output-contracts` | An agent's output feeds code rather than a human, and you need it to parse reliably. |
| `deterministic-enforcement` | A rule keeps getting violated despite being stated in the prompt. |
| `mcp-integration` | Deciding whether to expose a system through MCP, and how to scope the server. |
| `provenance-and-escalation` | Output needs to be traceable to sources, or the agent should hand off instead of guessing. |
| `skill-and-plugin-authoring` | Writing a skill that needs to be selected reliably and followed once loaded. |

## Audit and workflow skills

| Skill | Use it when |
| --- | --- |
| `config-audit` | One-shot health check of a whole Claude Code configuration — runs the skills, agents and hooks audits in parallel, adds a settings and permissions layering pass, and merges the result into one ranked report. |
| `claude-config-audit` | Auditing one repository's configuration end to end and fixing what you approve: CLAUDE.md hierarchy, skills, settings, hooks, and whether each is the right mechanism for the job. |
| `review-skills` | Auditing a tree of `SKILL.md` files for authoring quality, correct classification, and whether a skill triggers at all. |
| `review-agents` | Auditing a roster of subagent definitions for packaging, prompt quality, and selectability — including whether an agent should have been a skill. |
| `review-hooks` | Auditing hook scripts together with their settings registrations: cost, process overhead, event matching, and rules that should be mechanical rather than remembered. |
| `agent-sdk-review` | Surveying a codebase that uses the Agent SDK and reporting deviations from the design rules above, ranked by blast radius. |
| `debug` | Running a debugging session end to end: interview for symptoms, delegate read-only root-cause analysis, then apply and verify the fix where the test output is visible. |
| `repo-walkthrough` | Orienting in an unfamiliar codebase to the point of being able to contribute safely. |
| `handoff` | Writing a self-contained handoff another engineer or a fresh session can resume from, including what was already tried and ruled out. |
| `release-train` | Running one large change as an orchestrated release: a leader session supervising several named workers, each in its own git worktree, all converging on a shared release branch. Owns decomposing the work into provably disjoint bundles, verifying each worker's branch, and merge order. Forge-neutral — opening the resulting request belongs to `github-workflow`. |
| `session-sync` | Bringing every worktree of a repository current with its base branch without ever force-pushing: local rebase where the branch was never pushed, a server-side rebase via the installed forge adapter where a request is open, and nothing where being behind is harmless. |
| `design-intake` | Classifying a request as a spike, a bounded change or an architectural one, and running the matching process. The ceremony scales with the task; the approval gate before any implementation does not. |
| `writing-plans` | Turning an approved design into a plan another engineer can execute: a spec pointer, a constraints block reproduced verbatim, and per-task `Files` and `Interfaces` blocks. |

## Agents

All three are read-only. They report and never edit.

| Agent | Purpose |
| --- | --- |
| `agent-sdk-validator` | Completion gate for a change touching Agent SDK code. Checks the load-bearing conventions and returns `PASS`, `DRIFT`, `SKIP`, or `NO VERDICT` with file-anchored findings. |
| `adr-currency-validator` | Completion gate that checks whether Architecture Decision Records are in sync with a code change, and that the index row exists and is honest. |
| `debugger` | Root-cause analysis with falsifiable hypotheses tested against observed evidence. Returns a ranked diagnosis, a fix direction, and a verification step. Spawned by `debug`, or invoked directly. |

A denied or errored tool call is reported as `NO VERDICT` naming the blocker — never retried
into a hang, and never quietly downgraded to a pass.

## Tooling

The audit skills judge; these run. Both need a shell, so both are Claude Code only.

- **`scripts/eval/`** — measures whether a skill actually fires, by driving real `claude -p`
  sessions and reporting a trigger *rate*. Description optimisation selects on a **held-out**
  split, so a description is not tuned onto the same queries it is scored against. Every entry
  point prints the number of Claude sessions it will spend before spending any, and `--dry-run`
  spawns nothing.
- **`scripts/hooks/`** — runs a hook against a synthetic event, lints hook source, and validates
  a `hooks.json` registration. Calibrated against `dev-guardrails`: any finding these report
  against that package is a bug in these tools, not in it.

## Surfaces

Skills load in both Claude Code and Cowork (Claude Code on the web). **Subagents are Claude
Code only** — `agent-sdk-validator`, `adr-currency-validator` and `debugger` are unavailable in
Cowork, and so is the delegation step inside the `debug` skill, which falls back to reasoning
in the main thread.

The audit skills read a repository from disk. In Cowork there is no checkout and no shell, so
they work from configuration you paste into the conversation instead. The design skills do not
read anything and behave identically on both surfaces.

The two workflow runners are **Claude Code only**, with no fallback. `release-train` spawns
subagents, creates git worktrees and runs `git`; `session-sync` enumerates worktrees from disk and
runs `git`. Neither has a pasted-in equivalent, because in both cases the input is the state of the
working trees themselves rather than a configuration file.

## Installing

Install from the marketplace, then invoke a skill by name or let Claude select one from its
description.

## Scope

Design rules and audits only. For request/response shapes, field names, and current model
identifiers, check the official Claude API and Agent SDK documentation — those move faster
than this library does.

## License

MIT.
