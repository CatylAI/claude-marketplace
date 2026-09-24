# Structured output limits and parameters

> **Verify against current docs.** Limits, parameter names, and SDK helpers change. Check
> platform.claude.com ("Structured outputs", "Strict tool use") or the built-in `claude-api` skill
> before relying on a value here.

## Parameter names

The JSON output format is `output_config.format` (`{"type": "json_schema", "schema": {...}}`). It
replaced an earlier beta `output_format` request field; the API accepts the old spelling for a
transition period, but the Python SDK's `create()` rejects `output_format=` with a `TypeError`. The
Python `client.messages.parse()` helper still accepts `output_format=<PydanticModel>` as a
convenience and translates it. Other SDKs take `output_config` directly. The parsed result is on
`response.parsed_output`.

## Complexity budget

At time of writing, combined across all strict schemas in one request:

| Limit | Value | Counts |
| --- | --- | --- |
| Strict tools per request | 20 | Tools with `strict: true`; non-strict tools do not count |
| Optional parameters | 24 | Every parameter not in `required`, across strict tools and JSON output schemas |
| Union-typed parameters | 16 | Parameters using `anyOf` or type arrays such as `["string", "null"]` |

Beyond these, internal grammar-size limits surface as a schema-complexity error, and compilation can
time out. When you hit a limit, the docs suggest: make parameters required where a default is
reasonable, cut union types, flatten nesting, and split strict tools across requests or subagents.

## Grammar cache

Compiled grammars are cached for 24 hours from last use. Changing the schema structure or the set of
tools invalidates the cache; changing only a `name` or `description` does not.

## Invalid outputs

- `stop_reason: "refusal"` returns 200, is billed, and the output may not match the schema.
- `stop_reason: "max_tokens"` may return incomplete output; retry with a higher `max_tokens`.
- String `enum` and `const` values may differ from the schema only in capitalization, typically the
  first letter of a word after a space, with no error and no special `stop_reason`. This applies to
  JSON outputs and strict tool use.

## Compatibility

Works with batch processing, token counting, streaming, and strict tools in the same request. Returns
400 with citations enabled; incompatible with message prefilling. Grammars apply only to Claude's
direct output, not to thinking blocks or tool results.

## Data handling

Schemas are compiled into grammars cached separately from message content, and do not receive the
same protections as prompts and responses. Keep PHI and other sensitive data out of property names,
`enum` and `const` values, and `pattern` regexes.
