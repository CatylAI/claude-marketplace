# Tool API mechanics

> **Verify against current docs.** Beta identifiers, per-model restrictions, and measured savings
> change with each release. Check platform.claude.com ("Define tools", "Tool search tool",
> "Programmatic tool calling") or the built-in `claude-api` skill before relying on anything here.

## Forced `tool_choice` support

At time of writing, the "Define tools" page lists two restrictions on `tool_choice: any` and
`tool_choice: {type: "tool"}`:

- Manual extended thinking (`thinking: {type: "enabled"}`) rejects both; adaptive thinking does not
  by itself.
- Claude Opus 5.5, Claude Fable 5.1, and Claude Mythos 5.1 reject both with a 400 regardless of
  thinking settings. The docs recommend `auto` with strict tool use, or structured outputs.

Re-check this table for the model you ship.

## Tool search and deferred loading

A hot set kept resident, the tail deferred:

```json
{
  "tools": [
    { "type": "tool_search_tool_bm25_20251119", "name": "tool_search_tool_bm25" },

    { "name": "search_orders",        "description": "...", "input_schema": {} },
    { "name": "get_customer_context", "description": "...", "input_schema": {} },
    { "name": "process_refund",       "description": "...", "input_schema": {}, "strict": true },

    { "name": "tracker_search", "description": "...", "input_schema": {}, "defer_loading": true },
    { "name": "chat_search",    "description": "...", "input_schema": {}, "defer_loading": true }
  ]
}
```

The three tools used on nearly every turn stay in the prefix and stay cacheable; the long tail
loads only when a search surfaces it. A regex variant (`tool_search_tool_regex_20251119`) also
exists. The docs report that tool search typically cuts definition tokens by over 85%.

Documented errors: a request where every tool is deferred returns 400 ("at least one tool must have
defer_loading=false"); a deferred tool carrying `cache_control` returns 400.

## Programmatic tool calling

Measured savings reported in the docs: about 38% fewer billed input tokens on a 75-tool
project-management benchmark, and 24% fewer input tokens (with an 11% accuracy gain) on agentic
search benchmarks. Not supported with `strict: true` tools, with forcing a tool through
`tool_choice`, or with `disable_parallel_tool_use: true`.

## Tool definition limits

Tool names match `^[a-zA-Z0-9_-]{1,128}$`. `input_examples` must validate against `input_schema`
(an invalid example returns 400) and are not supported on server tools.
