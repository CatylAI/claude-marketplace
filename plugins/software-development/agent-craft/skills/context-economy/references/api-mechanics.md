# Context and cost mechanics

> **Verify against current docs.** Prices, per-model minimums, beta headers, strategy identifiers,
> and batch limits change with each model release. Check platform.claude.com ("Prompt caching",
> "Context editing", "Batch processing"), code.claude.com/docs/en/mcp, or the built-in `claude-api`
> skill before relying on a value here.

## Contents

- Prompt caching prices and minimums
- Claude Code MCP output limits
- Context editing: a working call
- Message Batches limits
- Batch pattern: sample, submit, resubmit failures

## Prompt caching prices and minimums

At time of writing:

- Cache writes cost 1.25x base input for the five-minute TTL and 2x for the one-hour TTL. Reads cost
  0.1x base input on most models, lower on some newer ones. A one-hour write pays back on its second
  cache hit.
- The minimum cacheable prefix ranges from 512 to 4,096 tokens depending on the model; it does not
  track model size. Read the per-model table on the "Prompt caching" page.
- The docs' invalidation table: changing tool definitions invalidates everything; `tool_choice`,
  images, and web-search or citations toggles invalidate from the system or message level down;
  thinking and effort settings are model-specific.

## Claude Code MCP output limits

Claude Code warns when an MCP tool's output exceeds 10,000 tokens and caps it at 25,000 tokens by
default. `MAX_MCP_OUTPUT_TOKENS` raises the cap (the warning threshold is fixed). A server can set
the `anthropic/maxResultSizeChars` annotation on a tool to set its own text limit. Built-in tools
are not governed by this setting.

## Context editing: a working call

Context editing is a beta: it needs the beta client and the beta header.

```python
response = client.beta.messages.create(
    betas=["context-management-2025-06-27"],
    model=MODEL,
    max_tokens=8192,
    tools=TOOLS,
    system=[{"type": "text", "text": SYSTEM_INSTRUCTIONS,
             "cache_control": {"type": "ephemeral"}}],
    context_management={
        "edits": [{
            "type": "clear_tool_uses_20250919",
            "trigger": {"type": "input_tokens", "value": 120_000},
            "clear_at_least": {"type": "input_tokens", "value": 20_000},
            "keep": {"type": "tool_uses", "value": 3},     # keep the 3 most recent
            "exclude_tools": ["get_case_facts"],           # this result has to survive
        }],
    },
    messages=messages,
)
```

The oldest results, the ones already acted on, clear automatically while message structure and call
inputs survive (set `clear_tool_inputs: true` to clear inputs too). Because cleared content sits
after the static prefix, tools and system keep hitting cache. Thinking blocks have their own strategy
(`clear_thinking_20251015`). For most long conversations the docs recommend server-side compaction
first.

## Message Batches limits

| Constraint | Value |
| --- | --- |
| Max per batch | 100,000 requests or 256 MB, whichever comes first |
| Completion | Most batches finish within an hour; results available when all complete, or at 24 hours |
| Expiry | Unfinished requests expire at 24 hours |
| Result retention | Downloadable for 29 days from creation |
| Price | 50% of standard input and output prices |
| Result order | Not guaranteed; correlate by `custom_id` |

## Batch pattern: sample, submit, resubmit failures

```js
// 1. calibrate on a small sample, synchronously
for (const d of docs.slice(0, 8)) {
  await client.messages.create({ model, max_tokens, messages: [{ role: "user", content: d }] });
}

// 2. submit the rest as a batch with correlatable ids
const batch = await client.messages.batches.create({
  requests: docs.map((d, i) => ({
    custom_id: `report-${i}`,
    params: {
      model, max_tokens,
      system: [{ type: "text", text: SYS, cache_control: { type: "ephemeral", ttl: "1h" } }],
      messages: [{ role: "user", content: d }],
    },
  })),
});

// 3. once it ends, resubmit only what failed, modified
const failed = results.filter(r => r.result.type !== "succeeded").map(r => r.custom_id);
```
