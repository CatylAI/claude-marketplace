# Loop API mechanics

> **Verify against current docs.** SDK method names, beta status, and Agent SDK result fields change
> between releases. Check the Claude API docs ("Handling stop reasons", "Tool Runner") and the Agent
> SDK reference, or the built-in `claude-api` skill, before relying on a name here.

## Stop reasons

The API documents these `stop_reason` values: `end_turn`, `tool_use`, `max_tokens`,
`stop_sequence`, `pause_turn`, `refusal`, `model_context_window_exceeded`. `stop_details` is
populated only for `refusal`, where it names the policy category. A response that leaves a client
`tool_use` block waiting never has `pause_turn`; that stop is always `tool_use`.

## The SDK tool runner

The tool runner is a beta helper in the official SDKs. In Python:

```python
runner = client.beta.messages.tool_runner(
    model=MODEL,
    max_tokens=4096,
    tools=[search_orders, get_customer],      # functions decorated with @beta_tool
    messages=[{"role": "user", "content": task}],
)
final = runner.until_done()                   # or iterate: `for message in runner: ...`
```

In TypeScript the method is `client.beta.messages.toolRunner(...)`. The runner loops until Claude
returns a message without a tool call, or until `max_iterations` if you set it. Set
`max_iterations` as the circuit breaker described in rule 4.

## Agent SDK caps and result subtypes

`ClaudeAgentOptions` (Python) takes `max_turns` and `max_budget_usd`; the TypeScript options use
`maxTurns` and `maxBudgetUsd`. The result `subtype` is one of `success`, `error_during_execution`,
`error_max_turns`, `error_max_budget_usd`, `error_max_structured_output_retries`.

Check `terminal_reason` before `subtype`: when the final API request fails, the SDK reports
`subtype: "success"` with the cause in `terminal_reason` (for example `api_error`). A limit you set
reports an `error_*` subtype.

```python
options = ClaudeAgentOptions(max_turns=40, max_budget_usd=2.00)
result = await run(options)                       # your wrapper around query()
if result.terminal_reason == "api_error" or (result.subtype or "").startswith("error_"):
    logger.error("agent run did not finish", extra={"task": task_id, "why": result.terminal_reason or result.subtype})
    return escalate(task_id, reason=result.terminal_reason or result.subtype)
```

## Error flags on tool results

The Claude API marks a failed tool result with `is_error: true` on the `tool_result` block; MCP uses
`isError: true`. Ownership of these fields is in `tool-interface-design`.
