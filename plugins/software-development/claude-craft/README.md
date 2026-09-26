# claude-craft

Architecture guidance for building systems on the Claude Agent SDK and the Messages API, plus
audits that check an existing Claude Code configuration against it.

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

## Audit skills

| Skill | Use it when |
| --- | --- |
| `config-audit` | Health-checking a whole Claude Code configuration: runs the skills, agents and hooks audits in parallel, adds a settings and permissions layering pass, and merges the result into one ranked report. With `--fix`, it also applies the changes you approve. |
| `review-skills` | Auditing a tree of `SKILL.md` files for authoring quality, correct classification, and whether a skill triggers at all. |
| `review-agents` | Auditing a roster of subagent definitions for packaging, prompt quality, and selectability — including whether an agent should have been a skill. |
| `review-hooks` | Auditing hook scripts together with their settings registrations: cost, process overhead, event matching, and rules that should be mechanical rather than remembered. |
| `agent-sdk-review` | Surveying a codebase that uses the Agent SDK and reporting deviations from the design rules above, ranked by blast radius. |

## Agent

| Agent | Purpose |
| --- | --- |
| `agent-sdk-validator` | Read-only completion gate for a change touching Agent SDK code. Checks the load-bearing conventions and returns `PASS`, `DRIFT`, `SKIP`, or `NO_VERDICT` with file-anchored findings. |

A denied or errored tool call is reported as `NO_VERDICT` naming the blocker, so a gate that
could not run is never mistaken for a pass.

## Tooling

**`scripts/hooks/`** runs a hook against a synthetic event, lints hook source, and validates a
`hooks.json` registration. `review-hooks` runs these before its judgement passes. They need a
shell and `jq`, so they are Claude Code only. They are calibrated against `dev-guardrails`: a
finding they report against that package is a bug in these tools.

## Reading order

Start with `agentic-loop-control` — a loop that mis-detects completion invalidates everything
above it. Then `tool-interface-design` and `output-contracts` for the agent's interfaces, then
`agent-orchestration` and `context-economy` once you are running more than one agent.

For the audits, start with `config-audit` if you want the whole picture and do not yet know where
the problems are; go straight to `review-skills`, `review-agents`, or `review-hooks` when you
already do. Add `--fix` to `config-audit` when you want it to change things rather than only
report.

## Conventions used here

Several skills recommend payload fields (`status`, `errorCategory`, `isRetryable`, provenance
blocks) that are conventions this library suggests, not platform features. Where that is the
case the skill says so. Adopt them consistently or not at all, and present them to your team as
conventions, not as part of the API.

## Surfaces

Skills load in Claude Code (including Claude Code on the web) and in Cowork and the claude.ai
apps. The `agent-sdk-validator` subagent is Claude Code only.

Design skills need no checkout; their Verify steps run commands in Claude Code and fall back to
pasted content in Cowork. The audit skills read a repository from disk in Claude Code; in Cowork
and claude.ai there is no checkout and no shell, so they work from configuration you paste into
the conversation instead. The `scripts/hooks/` checks need a shell and do not run there.

## Moved

Earlier versions of this plugin shipped general engineering workflows. They now live with
related skills:

| Was here | Now |
| --- | --- |
| `debug` | `engineering-workflows:root-cause` |
| `handoff`, `repo-walkthrough`, `design-intake`, `writing-plans`, `release-train` | `engineering-workflows` (same names) |
| `debugger` agent | `engineering-workflows` |
| `session-sync` | `dev-guardrails:session-sync` |
| `adr-currency-validator` agent | `project-scaffold` |
| `claude-config-audit` | merged into `config-audit` (use `--fix`) |
| `scripts/eval/` | removed; use the skill-creator skill's evals, or `claude plugin eval` |

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install claude-craft@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

Then invoke a skill by name, or let Claude select one from its description.

## Scope

Design rules and audits only. For request/response shapes, field names, and current model
identifiers, check the official Claude API and Agent SDK documentation — those move faster
than this library does.

## License

MIT.
