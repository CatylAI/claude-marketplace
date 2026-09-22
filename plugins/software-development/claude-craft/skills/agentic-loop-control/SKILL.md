---
name: agentic-loop-control
description: "How an agent loop should terminate, continue, and fail: branching on stop_reason instead of on model prose, appending every tool result before the next request, choosing a managed loop over a hand-rolled one, using turn and budget caps as circuit breakers, retrying only with the specific error, and propagating failures as structured partial results. Use when writing or reviewing a Messages API loop, when an agent stops early or spins forever or repeats the same tool call, or when deciding how a tool failure should reach the caller. Not for subagent design or tool schema design."
license: MIT
---

# Agentic loop control

The loop is the one part of an agent that must be fully deterministic. Nearly every loop bug
traces to the same root cause: something the control flow should have decided was left to the
model's prose instead.

Loop correctness ranks above every other concern in an agent system. A perfectly described tool
inside a loop that mis-detects completion is still a broken agent.

## 1. Terminate on `stop_reason`, never on content

`stop_reason` is the only completion signal the API gives you. Treat `end_turn` as finished and
every other value as "not finished — find out why."

| `stop_reason` | What happened | What to do |
| --- | --- | --- |
| `end_turn` | Model finished on its own | Return. |
| `tool_use` | The turn contains `tool_use` blocks | Execute, append results, iterate. |
| `max_tokens` | Output truncated, possibly mid-`tool_use` with partial JSON | Raise the limit and retry, or repair the partial input. Never parse truncated tool input as if it were complete. |
| `model_context_window_exceeded` | Context limit hit | Compact, trim, or escalate. Re-sending the same request cannot succeed. |
| `pause_turn` | A long-running server-tool turn checkpointed | Re-send the paused assistant content verbatim to continue. No client `tool_use` block is left unanswered. |
| `refusal` | Safety decline, with `stop_details` | Not retryable against the same model. Fall back or escalate. |
| `stop_sequence` | A configured stop sequence matched | Handle per your own protocol. |

The asymmetry that catches people: under structured output, both `refusal` and `max_tokens` can
return a payload that violates your schema. Schema guarantees hold only for a turn that ended
normally.

## 2. Append both halves of every tool exchange

The Messages API is stateless — each request carries the whole conversation. A tool result that
never makes it into `messages` is a result the model cannot reason about, and the symptom is an
agent that calls the same tool over and over.

Append the assistant turn carrying the `tool_use` blocks **and** the user turn carrying one
`tool_result` per `tool_use_id`, in order. Never one without the other.

## 3. Take the highest rung of the loop ladder that works

1. **`client.beta.messages.tool_runner(...)`** — the SDK's own loop. Runs your tools, formats
   results, iterates to `end_turn`. The default for ordinary agentic work.
2. **Managed Agents** (server-hosted) — Anthropic runs the loop and a sandbox, persists event
   history, streams results. For long-running autonomous work you would rather not host.
3. **A hand-written `while` loop** — only when you need something the managed loop will not do:
   human approval gates, conditional execution, custom batching, per-iteration policy checks,
   bespoke telemetry.

Writing rung 3 when rung 1 would do is the most common piece of avoidable agent code, and it is
where rules 1 and 2 get broken.

## 4. Caps bound blast radius; they do not decide completion

`maxTurns` / `max_turns` and `maxBudgetUsd` / `max_budget_usd` are circuit breakers. Tripping one
produces a result with an error subtype such as `error_max_turns`. That is an incident to log and
surface, not a success to return. An agent that routinely ends on the cap has a decomposition
problem, not a cap problem.

Never make an iteration counter the primary completion test.

## 5. Retry with the defect named, or do not retry

A retry that does not tell the model what was wrong reproduces the same failure at full cost.
A retry payload needs three things: the original input, the output that failed, and the specific
validation error.

Know the boundary. Retries fix format mismatches, misplaced values, and skipped arithmetic. They
cannot conjure information that is not in the source — for that, return `null` where the schema
allows it, or route to a human. Retrying for missing data is how fabrication enters a pipeline.

Categorize first:

| Category | Retryable | Action |
| --- | --- | --- |
| Transient — timeout, 5xx, rate limit | Yes, as-is | Backoff and retry |
| Validation — bad input shape | Yes, after fixing | Retry with the error text included |
| Business — policy limit, ineligible | No | Alternative path or escalation |
| Permission — wrong principal | No | Different credential or escalation |

## 6. Propagate failure with structure

Two catastrophic patterns:

- **Silent suppression.** An empty result marked success. The caller believes the operation ran
  and found nothing, so coverage gaps become invisible.
- **Whole-run abort.** One source fails and the run dies, discarding work that already succeeded
  and already cost money.

Attempt local recovery for transient failures, then propagate a structured partial result
carrying the failure category, what was attempted, whatever partial results exist, and suggested
alternatives. Above all, make a valid empty result *structurally different* from an access
failure: "the query ran and matched nothing" is a success; "the source was unreachable" is not.

## Audit checklist

- [ ] Exactly one place decides the agent is done, and it reads `stop_reason`.
- [ ] Grep for `content[0]`, `.text.includes(`, `"DONE"`, `TASK_COMPLETE` in control flow — each
      hit is a rule 1 violation.
- [ ] `pause_turn`, `max_tokens`, `model_context_window_exceeded`, and `refusal` are each handled
      by name; there is no bare `else { break }`.
- [ ] Every `tool_use` gets a matching `tool_result`, in order, before the next request.
- [ ] If the loop is hand-written, you can name the specific interception that justifies it.
- [ ] Hitting a cap logs and escalates rather than returning a normal-looking result.
- [ ] Retries carry the validation error text, and no retry path exists for missing source data.
- [ ] A caller can tell `results: []` (no match) from `results: []` (source down).
- [ ] One tool failure does not abort the run and discard completed work.

## Patterns that hold up

**Every exit named.**

```js
while (true) {
  const res = await client.messages.create({ model, max_tokens, messages, tools });

  if (res.stop_reason === "end_turn") return res;

  if (res.stop_reason === "tool_use") {
    const toolResults = await runTools(res);          // one per tool_use_id
    messages.push({ role: "assistant", content: res.content });
    messages.push({ role: "user", content: toolResults });
    continue;
  }

  if (res.stop_reason === "pause_turn") {
    messages.push({ role: "assistant", content: res.content });  // verbatim
    continue;
  }

  if (res.stop_reason === "max_tokens") throw new TruncatedTurn(res);
  if (res.stop_reason === "model_context_window_exceeded") throw new ContextExhausted(res);
  if (res.stop_reason === "refusal") return escalate(res);
  throw new UnhandledStopReason(res.stop_reason);
}
```

The final `throw` is the point of the shape: a `stop_reason` shipped after you wrote this lands
somewhere loud instead of being silently read as completion.

**The managed loop when nothing needs intercepting.**

```python
runner = client.beta.messages.tool_runner(
    model=MODEL,
    max_tokens=4096,
    tools=[search_orders, get_customer],
    messages=[{"role": "user", "content": task}],
)
for message in runner:
    pass                      # iterates until end_turn
final = message
```

**A retry aimed at the actual defect.**

```js
const retry = [{ role: "user", content:
  `Original document:\n${doc}\n\n` +
  `Your extraction:\n${JSON.stringify(failed)}\n\n` +
  `Validation error: line items sum to 450.00 but stated_total is 500.00. ` +
  `Re-extract every line item, including any on page 2.` }];
```

The model now knows which invariant broke and where to look — unlike "that was wrong, try
again," which changes nothing about its information state.

**A partial failure the caller can act on.**

```json
{
  "status": "partial_failure",
  "errorCategory": "transient",
  "isRetryable": true,
  "attemptedAction": { "tool": "search_academic_db", "query": "grid storage policy", "dateRange": "2022-2024" },
  "partialResults": [{ "title": "Grid Storage Directive 2023", "source": "public register" }],
  "alternativeApproaches": ["Narrow to 2023-2024", "Try government_publications", "Use cached results"]
}
```

**A cap that is monitored.**

```python
options = ClaudeAgentOptions(max_turns=40, max_budget_usd=2.00)
result = await run(options)
if getattr(result, "subtype", None) == "error_max_turns":
    logger.error("agent hit turn cap", extra={"task": task_id})
    return escalate(task_id, reason="turn_cap")
```

## Failure modes

**Text presence read as completion.**

```js
if (res.content[0].type === "text") return res;     // broken
```

A model can emit text alongside `tool_use` in the same turn. This returns mid-task with tools
unexecuted, and it fails intermittently — it depends on whether the model narrated before
calling.

**A loop bounded only by a counter.**

```python
for _ in range(10):
    res = call_model(messages)
    messages.append(res)        # tool results never appended
```

Two defects compounding: completion decided by exhaustion, and results that never reach the
model, so it re-requests the same tools until the counter runs out. Reads as "the model is dumb";
is actually rule 2.

**`pause_turn` treated as an error, or rewritten.** Aborting discards completed work.
Summarizing the paused assistant content and sending the summary breaks the continuation
contract. Append it verbatim.

**Retry with no error context.** Identical inputs produce a near-identical failure — three
attempts for 3x the cost and no new information. If the data is genuinely absent, the extra
attempts pressure the model to invent it.

**Empty marked success, or the run aborted.**

```json
{ "results": [], "status": "success" }
```

Makes a source outage indistinguishable from "nothing matched," so the caller reports a gap as a
finding.

## Porting to other stacks

These are control-flow rules, not SDK rules.

- **LangGraph and other state machines** — the conditional edge out of the model node must read
  the raw stop reason off the response, not a parsed field or a regex over content. Put the cap
  on `recursion_limit` and treat hitting it as a graph error, not a terminal state.
- **OpenAI-style loops** — `finish_reason` covers less ground (`stop`, `tool_calls`, `length`,
  `content_filter`). `length` is the `max_tokens` analogue; there is no `pause_turn` equivalent,
  so checkpointing long server-tool turns is yours to solve. The append rule is identical.
- **Anywhere** — the four error categories and the empty-vs-unreachable distinction belong in
  your tool wrapper layer. No protocol hands them to you.

## Scope note

The API's tool-result failure flag is `is_error` (snake_case) on a `tool_result` block; MCP's is
`isError` (camelCase) on a tool result. `status: "partial_failure"`, `errorCategory`,
`isRetryable`, and `alternativeApproaches` are **not** in either specification — they are a
convention recommended here for the inside of your result payload. Adopt them consistently, but
do not describe them to your team as platform features. Confirm current `stop_reason` values and
field names against the Claude API documentation before relying on them.
