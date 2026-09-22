---
name: agent-sdk-review
license: MIT
description: "Survey a codebase that uses the Claude Agent SDK and report where it deviates from the design rules, ranked by blast radius. Uses parallel read-only exploration to check loop control (does it branch on stop_reason or on parsed prose?), orchestration shape and explicit subagent context, tool interface quality, structured tool errors and fail-closed authorization, context-window management, validated structured output, provenance, and escalation. Returns file-anchored findings with recommended fixes; it never edits. Use when onboarding an agent codebase, spot-checking before review, or when unsure whether agent code follows the conventions. Not for a gate on one specific diff — that is the agent-sdk-validator agent — and not for code built on a different agent framework."
when_to_use: "review my agent code, audit an agent SDK codebase, check the agent loop, is this hub-and-spoke, agent error handling review, why does my agent never stop, onboard an agent codebase"
user-invocable: true
disable-model-invocation: true
argument-hint: "[optional path to a repository or agent directory; defaults to the current directory]"
allowed-tools: Read, Glob, Grep, Bash(find:*), Bash(ls:*), Bash(git:*), Bash(echo:*), Bash(grep:*), Agent, AskUserQuestion
context: fork
---

# Review Claude Agent SDK Code

A **read-only** survey of how an agent is built. It maps the implementation against the design
rules below, ranks deviations by blast radius, and reports fixes. It does not edit — the caller
applies fixes and re-runs.

For a pass-or-fail gate on one specific diff, use the `agent-sdk-validator` agent instead. This
skill is the broader survey.

## Step 1 — Gather context and confirm the subject

The target is the path passed as an argument if there is one, otherwise the current
directory. Run these against it and work from the output — if your shell does not bind `$1`,
substitute the resolved target path for `${1:-.}` before running them:

```bash
echo "${1:-$(pwd)}"
git rev-parse --is-inside-work-tree 2>/dev/null || echo "no"
grep -rlE "claude-agent-sdk|@anthropic-ai/(sdk|claude-agent-sdk)|anthropic" "${1:-.}" --include='*.ts' --include='*.js' --include='*.py' 2>/dev/null | head -20
grep -rlE "tool_use|tool_result|input_schema|inputSchema" "${1:-.}" --include='*.ts' --include='*.js' --include='*.py' 2>/dev/null | head -20
```

In order: the resolved target, whether it is a git repository, the files that import the
Agent SDK, and the files that probably define tools. The stop condition immediately below
turns on the third command's output, and Step 2's subagents are pointed at the last two
listings.

If you cannot run commands here — a surface with no shell — ask the user to paste the output
and wait for it. An empty listing you did not actually produce is not evidence that the SDK
is absent, and a review of code you never read is exactly the failure this skill exists to
find in other people's agents.

If nothing imports the SDK, say so and stop. This skill reviews Claude Agent SDK code — not generic
model calls, and not another vendor's agent framework. If the codebase mixes frameworks, scope the
review to the Agent SDK portion and say which parts you excluded.

## Step 2 — Survey in parallel

Launch read-only exploration subagents (up to three), each covering one band of the rules. Narrow
to the given path if one was passed. Each returns **discrete findings only**: the problem, the file
and line, the rule violated, and the recommended fix. No edits.

### Band 1 — Loop and orchestration

- Does the loop branch on `stop_reason`, or does it pattern-match the assistant's prose for
  completion? Text matching is the single most common defect here and it fails silently.
- Is every `tool_use` block answered by an appended `tool_result` in the next user turn, including
  on the error path? An unanswered `tool_use` corrupts the conversation.
- Is a truncated response — hitting the token ceiling — distinguished from a finished one?
- Is the loop bounded by turns and by spend, and does it do something sensible at the bound rather
  than terminating silently?
- Is multi-agent work hub-and-spoke, with a coordinator owning the result, rather than subagents
  chaining peer to peer?
- Is context passed into a subagent **explicitly**? A prompt saying "based on your earlier
  findings" assumes a window the subagent does not have.
- See `agentic-loop-control` and `agent-orchestration` for the full rules.

### Band 2 — Tool interfaces and errors

- Do tool descriptions read like documentation a competent stranger could use, including when
  *not* to call the tool? An empty or one-word description is a selection failure waiting to
  happen.
- Are inputs typed and narrow, with enums where the set is closed?
- Are outputs bounded — paginated, aggregated, or truncated at a stated ceiling — rather than
  returning whatever the underlying call produced?
- Do tools return **structured** errors the loop can act on (an error flag, a category, a
  retryability derived from the actual failure) rather than throwing into the loop or returning a
  bare string? A hardcoded "retryable: true" is the same defect as no field at all.
- Do authorization and permission failures fail **closed**? A permission check that returns an
  empty result on error is indistinguishable from a legitimate empty result.
- See `tool-interface-design`.

### Band 3 — Context, output, enforcement, escalation

- Is the context window managed: large tool results summarized or dropped at the boundary, heavy
  investigation delegated rather than inlined?
- Is output consumed downstream validated against a schema, with a retry on a miss rather than a
  silent coercion?
- Are expensive or irreversible actions — writes, deploys, spend, outbound messages — gated in
  code, or only by an instruction in the prompt? An instruction holds usually; that is the whole
  finding.
- Is provenance carried on data returned from subagents and tools, so the coordinator can tell what
  it is acting on?
- Does the agent escalate when it is blocked, out of retries, or uncertain on a high-stakes step,
  instead of guessing?
- See `context-economy`, `output-contracts`, `deterministic-enforcement`, and
  `provenance-and-escalation`.

## Step 3 — Rank by blast radius

Consolidate, highest consequence first. The ranking axis is what one failure costs:

1. An irreversible action gated only by a prompt.
2. An unvalidated write, or output coerced past a failed validation.
3. A missing `tool_result`, or a throw that corrupts the loop.
4. An unbounded loop or an unbounded tool response.
5. Authorization that fails open.
6. Everything else — vague descriptions, untyped inputs, missing provenance.

Format each finding:

```
FINDING-N: <file:line> — <problem> → <fix>  [<rule>]
```

If the caller wants to act interactively, offer the findings with `AskUserQuestion` as a
multi-select so they can pick what to hand off for fixing. Otherwise return the ranked report.

## Step 4 — Summarize

Lead with the top blast-radius risks, one line each, then the full list.

## Rules

- Read-only. Never edit agent code — report and hand off.
- Never cite a file, line, or rule you did not read.
- A codebase that already follows the conventions gets a clean report. Do not manufacture findings
  to look thorough.
- Distinguish frameworks before flagging. A pattern from a different agent framework is not a
  violation of these rules.
