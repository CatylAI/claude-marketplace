---
name: tool-interface-design
description: "Designing the tools an agent calls: descriptions long enough to decide selection (including when not to use a tool), namespacing by service and resource, consolidating a call chain into one capable tool, returning high-signal responses with a token ceiling, writing errors as prompts that teach the correct call, tool-count thresholds and deferred loading, tool_choice and strict schemas, and using search/glob/edit primitives as designed. Use when writing or reviewing a tool or MCP tool definition, when the agent picks the wrong tool or passes wrong parameters, or when tool responses are flooding the context window. Not for MCP server configuration or for enforcing call order."
license: MIT
---

# Tool interface design

A tool is a contract between a deterministic system and a non-deterministic one. Design it for an
agent with a limited context window, not for a developer with a debugger.

Descriptions come first. Expanding a description is the cheapest and highest-leverage fix for
almost every tool-selection problem. Classifiers, routers, few-shot examples, and consolidation
are what you reach for *after* the descriptions are genuinely good.

## 1. Description depth dominates tool performance

Anthropic's own guidance calls detailed descriptions by far the most important factor in tool
performance, and suggests at least three to four sentences per tool, more for a complex one.

Cover five things:

1. What the tool does.
2. When to use it — **and when not to**.
3. What each parameter means and how it changes behavior.
4. Caveats and limits, including what the tool does *not* return.
5. Explicit boundaries against the neighboring tools it gets confused with.

Write it the way you would brief a new hire: make implicit context explicit — query formats,
niche terminology, relationships between the underlying resources. Name parameters
unambiguously (`user_id`, not `user`). For nested or format-sensitive inputs, add
schema-validated input examples, as a supplement to the description rather than a substitute.

Tool names must match `^[a-zA-Z0-9_-]{1,128}$`.

## 2. Namespace by service and resource

With dozens of servers and hundreds of tools in play, overlapping or vaguely-purposed tools cause
confusion. Group with common prefixes: `tracker_search` / `chat_search` by service,
`tracker_projects_search` / `tracker_users_search` by resource. Prefix versus suffix has
measurable, model-dependent effects — choose one by evaluation and then stay consistent.

## 3. Build for the workflow, not for the endpoint

The common error is wrapping existing functions one-for-one. Agents have different affordances
than programs: computer memory is cheap, agent context is not. A tool that returns all contacts
so the agent can scan them is brute-force search charged to the context window.

| Instead of | Build |
| --- | --- |
| `list_users` + `list_events` + `create_event` | `schedule_event`, which finds availability and books |
| `read_logs` | `search_logs`, returning matching lines with surrounding context |
| `get_customer_by_id` + `list_transactions` + `list_notes` | `get_customer_context` |
| `create_pr` + `review_pr` + `merge_pr` | one tool with an `action` parameter |

Fewer, more capable tools reduce selection ambiguity. Each still needs a clear, distinct purpose —
consolidation is not a license to build a god-tool.

## 4. Return high signal, and cap the volume

**Quality.** Return semantic, interpretable values: prefer `name`, `file_type`, `image_url` over
`uuid`, `mime_type`, `256px_image_url`. Resolving opaque identifiers to meaningful names — or
even to a zero-indexed scheme — measurably reduces hallucination in retrieval tasks. When the
agent genuinely needs technical IDs to chain calls, expose a `response_format` enum
(`concise` | `detailed`) and let it choose; a documented example cut token use to about a third
in concise mode.

**Quantity.** Implement pagination, range selection, filtering, and truncation with sensible
defaults on anything that can grow. For calibration, Claude Code warns above 10,000 tokens of MCP
tool output and caps it at 25,000 by default; built-in tools are not governed by that setting, so
adopt your own comparable ceiling. When you truncate, say so and steer — tell the agent to make
several small targeted searches rather than one broad one.

Response structure (JSON vs. XML vs. Markdown) measurably affects performance with no universal
winner. Pick by evaluation.

## 5. Errors are prompts

A validation failure is a chance to teach the correct call. Return specific, actionable guidance
and a correctly formatted example — never an opaque code or a stack trace.

```text
Bad:  "Error: 400 Bad Request"
Bad:  "ValidationError at $.filters[0].op"
Good: "Invalid `date_range`: expected ISO 8601 like '2026-01-15/2026-03-31', got 'last quarter'.
       Resolve relative dates before calling. Example: {\"date_range\": \"2026-01-01/2026-03-31\"}"
```

Flag failures precisely: the Claude API uses `is_error: true` on the `tool_result` content block
(snake_case); MCP uses `isError: true` on the tool result (camelCase), and MCP results may also
carry structured content and resource links. Fields like `errorCategory` and `isRetryable` are in
neither specification — they are a convention worth adopting inside your payload, not a platform
feature to advertise to your team.

And make a valid empty result structurally distinct from a failure. "The query ran and matched
nothing" is a success with a count of zero; "the source was unreachable" is an error.

## 6. Know the real tool-count thresholds

"Four or five tools per agent" is folklore. The documented reality:

- Selection accuracy degrades past roughly 30–50 tools.
- Under 10 tools, or under about 100 tokens of definitions total, plain tool calling is best.
- At 10+ tools, definitions over roughly 10k tokens, or when aggregating MCP servers into the
  hundreds of tools, use the **tool search tool**: add the search tool to `tools`, then set
  `defer_loading: true` on the tools that should not load up front. Keep your three to five
  most-used tools non-deferred. At least one tool must be non-deferred or the request fails, and
  `defer_loading` cannot be combined with `cache_control` on the same tool. Reported saving is
  over 85% of definition tokens.
- When the agent would otherwise call many tools in sequence and pipe results between them,
  consider **programmatic tool calling**, which lets Claude orchestrate your tools from inside
  code execution so intermediate results never enter context. Documented saving is roughly
  20–40% of billed input tokens in the 10–49 tool range. It is incompatible with strict schemas,
  with disabling parallel tool use, and with forcing a specific tool.

Role-scoping still matters, but for a different reason: a synthesis agent holding a search tool
will research instead of synthesize. Scope by capability boundary; size by these thresholds.
Verify the exact beta identifiers and limits against current documentation before shipping.

## 7. Set `tool_choice` deliberately

| Value | Semantics | Use for |
| --- | --- | --- |
| `auto` | Claude decides whether and which to call; default when tools are present | General operation |
| `any` | Must call one of the tools, unspecified which | Guaranteeing a structured call among several schemas |
| `{type: "tool", name: "X"}` | Forces that exact tool | A mandatory first step — then drop back to `auto` |
| `none` | No tool use; default when no tools | A turn that must be prose |

With `any` or a named tool the API prefills the assistant turn, so the model emits no natural
language before the call — do not use them on a turn where you also want narration. Both are
rejected alongside manually enabled extended thinking. Changing `tool_choice` invalidates cached
message blocks, though tool definitions and the system prompt stay cached.

For guaranteed-valid parameters, set `strict: true` on the definition — grammar-constrained
sampling over the tool name and input. Combine it with `tool_choice: {"type": "any"}` when you
need a forced call with a guaranteed shape. Budget carefully: documented caps are 20 strict tools
per request, 24 optional parameters, and 16 union-typed parameters across all strict schemas
combined. Reserve strictness for tools where a schema violation does real damage.

## 8. Use the built-in primitives as designed

**Content search versus path matching.** Grep searches file contents; Glob matches file paths by
name. Callers, error strings, imports go to Grep. Test files, configs, every `.ts` in a directory
go to Glob.

**Edit with a unique anchor is how you modify a file.** On a non-unique match, stay on Edit:
widen the anchor with more surrounding context, or set `replace_all: true`. Read plus Write is a
last resort — it costs a whole file's tokens in and a whole file's tokens out.

**Explore incrementally.** Grep for entry points, Read to follow imports, Grep to trace usage,
Read only what the previous step justified. Reading every file up front is the fastest way to
exhaust a context budget.

## Audit checklist

- [ ] Every description runs three or more sentences and states when *not* to use the tool.
- [ ] Every pair of confusable tools has a boundary sentence pointing at the other.
- [ ] Parameter names are unambiguous; complex inputs carry examples.
- [ ] Names are namespaced by service, consistently prefix- or suffix-style.
- [ ] No tool exists purely because an endpoint exists; chains the agent always performs have
      been collapsed.
- [ ] No tool returns unbounded results; there is a token ceiling and a pagination default.
- [ ] Responses do not leak UUIDs, mime types, ACL hashes, or epoch millis the agent cannot use.
- [ ] A `response_format` (or equivalent) lets the agent ask for less.
- [ ] Every error names the defect and shows a correct example.
- [ ] The caller can tell "matched nothing" from "source unreachable."
- [ ] Tool count under 10 uses plain calling; 10+ or heavy definitions use deferred loading with
      three to five hot tools resident.
- [ ] `tool_choice` is never `any` or a named tool on a turn that also needs prose.
- [ ] Strict schemas are scoped to high-stakes tools and within the documented budgets.
- [ ] No Read-then-Write immediately following a failed Edit.

## Patterns that hold up

**Descriptions with explicit boundaries.**

```text
get_customer:
  "Look up a single customer by email address, phone number, or customer ID (format C-NNNN).
   Returns the profile: legal name, contact details, account status, loyalty tier, and account
   creation date. Use this to verify identity before any account-affecting action, and to
   resolve a human-supplied identifier into a customer ID for other tools. Returns at most one
   record; if the identifier is ambiguous it returns all candidate matches with ambiguous: true
   and takes no action. Does NOT return orders, transactions, or support history. Do NOT use for
   order questions — use lookup_order."

lookup_order:
  "Retrieve one order by order number (#NNNNN) or carrier tracking ID. Returns status, line
   items, shipping and delivery events, and refund eligibility with the reason when ineligible.
   Use when the user references a specific order or shipment. Does NOT return customer profile
   data and cannot search by customer — resolve identity with get_customer first. Do NOT use to
   list a customer's orders; use list_customer_orders."
```

Purpose, triggers, negative triggers, the ambiguity contract, and the deliberate omissions are
all present, so misrouting becomes structurally unlikely rather than probabilistically
discouraged.

**A consolidated tool replacing a chain.**

```python
@beta_tool
async def get_customer_context(customer_id: str, response_format: str = "concise") -> str:
    """Compile everything needed to act on a customer in one call: profile, the five most recent
    orders, open support tickets, lifetime value, and refund history for the last 12 months.
    Use at the start of any customer-facing task instead of chaining get_customer,
    list_transactions, and list_notes. response_format "concise" omits internal IDs and
    timestamps (about a third of the tokens); "detailed" includes the IDs required to call
    process_refund or update_subscription. Does NOT include payment instrument details."""
```

**A hot set kept resident, the tail deferred.**

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
loads only when a search surfaces it. Strictness is spent on the one tool that moves money.

**Errors and empty results the agent can act on.**

```json
// validation failure — teaches the correct call
{ "is_error": true,
  "content": [{ "type": "text", "text":
    "Invalid `order_id`: expected '#NNNNN' (5 digits), got 'last one'. Resolve the reference to a concrete order first — call list_customer_orders(customer_id) and pick from the result. Example: {\"order_id\": \"#88912\"}" }] }

// business rule — retrying cannot help
{ "is_error": true, "errorCategory": "business", "isRetryable": false,
  "content": [{ "type": "text", "text":
    "Refund of 750.00 GBP exceeds the 500.00 GBP auto-approval limit. Escalate for manager approval via create_approval_request; do not retry this call." }] }

// queried successfully, nothing matched — not an error
{ "is_error": false, "resultCount": 0,
  "content": [{ "type": "text", "text":
    "No customer matched that address. The directory was reachable and the query completed; there is no such record. Ask the user for an alternate identifier." }] }
```

**A non-unique edit anchor handled on Edit.**

```text
Edit(file, old_string="  return result;")                        -> fails, 6 matches
Edit(file, old_string="    const result = normalize(raw);\n    return result;\n  }\n}")   works
Edit(file, old_string="  return result;", replace_all=true)      also works, when all should change
```

## Failure modes

**Minimal descriptions, then a classifier to compensate.** `get_customer: "Retrieves customer
information"` next to `lookup_order: "Retrieves order details"` never tells the model the
boundary, so it guesses. Adding a routing model in front buys latency, infrastructure, and a
second thing to keep in sync; few-shot examples add tokens to every request; merging the tools
destroys the distinction. Expand the descriptions first, then check the system prompt for
keyword-sensitive instructions overriding them.

**One tool per endpoint.** `list_contacts` returning 4,000 records, unpaginated `list_orders`,
and a `get_note` / `get_note_tags` / `get_note_author` / `get_note_attachments` quartet. That is
the endpoint's shape, not the workflow's, and the agent burns its window reading records to find
one.

**Raw payloads full of opaque identifiers.**

```json
{ "results": [{ "id": "a3f9c1e8-4b2d-4f77-9c21-d8e0ab5512ff",
  "mime_type": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "thumb_256_url": "https://cdn/...", "acl_hash": "9f2b...", "shard": 14,
  "created_ts_ms": 1738291200123, "title": "Q3 plan" }] }
```

Nearly every token is unusable, and the UUID is a hallucination magnet — the model will recall it
slightly wrong on the next call. Return `{"title": "Q3 plan", "file_type": "docx", "modified":
"2026-01-31"}` in concise mode and expose the ID only in detailed mode.

**Piling on tools, or deferring all of them.** Eighteen resident un-namespaced tools on one agent
sits below the degradation band but wastes prefix tokens on every request and mixes roles, so the
agent reaches for off-role tools. Deferring every tool is an outright API error, and even if it
were legal it would force a search call before every action.

**Forcing a tool on a turn that needs narration, or strictness everywhere.** Forced choice
prefills the assistant turn, so the explanation you wanted never appears. Blanket strictness
blows the documented budgets and produces schema-complexity errors plus grammar recompilation
latency on every schema change.

**Path/content search confusion and the Read-then-Write reflex.** Globbing `**/*.ts` and reading
each file to find callers is a context bomb where one Grep would answer. Grepping for
`*.test.ts` searches contents for a filename pattern. Falling back from a failed Edit to a full
rewrite pays whole-file tokens twice for a one-line change.

## Porting to other stacks

- **OpenAI function calling and Agents SDK** — description depth, namespacing, consolidation, and
  high-signal responses transfer verbatim; they are model-ergonomics rules, not vendor features.
  `tool_choice` has the same four shapes and strict function schemas are the analogue of strict
  tool use. There is no tool-search equivalent, so at high tool counts you must build your own
  retrieval-over-tools layer; the 30–50 degradation band still applies.
- **LangChain tools** — the docstring *is* the description, so short docstrings are the default
  failure mode. Set an args schema with per-field descriptions rather than relying on inferred
  types, and return strings you designed rather than the repr of an ORM object.
- **MCP servers** — the same rules, plus annotations disclosing destructive or open-world
  behavior. Remember `isError` here versus `is_error` in the Claude API, and normalize at your
  boundary.
- **Anywhere** — "errors are prompts" and "empty is not unreachable" are the two rules teams most
  often skip and most often regret.

## Scope note

"Four or five tools per agent" appears in no official documentation; it is community folklore.
The defensible numbers are the thresholds above. Role-scoping remains correct, but justify it by
capability boundaries rather than by an invented tool count. Beta identifiers, strict-schema
budgets, and output ceilings all move — confirm them against current documentation before you
depend on a specific value.
