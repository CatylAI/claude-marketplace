---
name: context-economy
description: "Spending context and tokens well: prompt cache layout and breakpoint placement, keeping the prefix stable, trimming tool results at the boundary before they enter history, pinning transactional facts against summarization, putting key findings first, platform context editing and auto-compaction, just-in-time retrieval over pre-loading, deferred tool definitions, and routing latency-tolerant volume to the batch API. Use when an agent is slow or expensive, cache hit rates are near zero, the window fills up, or the agent loses specifics it found earlier. Not for loop control or subagent structure."
license: MIT
---

# Context economy

Context is the scarcest resource an agent has and the most commonly wasted. Two budgets are in
play: **attention** — what the model can reason about well — and **money**, what you are billed.
Most rules here improve both. Where they conflict, attention wins.

Structural fixes come before bigger windows. A larger window does not repair diluted attention.

## 1. Aim for the smallest set of high-signal tokens

That is the design target, and it is not the same as "include everything relevant." Four
techniques carry most of the weight:

- **Right-altitude system prompts** — specific enough to guide behavior, flexible enough to read
  as strong heuristics rather than a brittle script. Neither a list of hardcoded if-thens nor a
  vague aspiration.
- **Just-in-time retrieval over pre-loading** — let the agent navigate to what it needs via file
  structure, search, and targeted reads rather than stuffing candidate context in up front.
- **Structured note-taking** — persist findings outside the window and read them back.
- **Subagent isolation and deliberate compaction** — push verbose investigation into a separate
  window that returns a summary, and prune on purpose rather than letting the window fill.

## 2. Lay the prompt out for the cache, then place the breakpoint

Mechanics to design around:

- The marker is `cache_control: {"type": "ephemeral"}` on a content block.
- There is a maximum of four breakpoints per request.
- The minimum cacheable prefix is **model-specific**, documented across a range from roughly 512
  to 4,096 tokens, and smaller models generally need *longer* prefixes. Look up the model you
  ship before assuming anything — a prefix under the threshold silently fails to cache, and that
  is the most common cause of a zero hit rate.
- TTL is five minutes by default, or one hour on request. A write costs more than base input
  (about 1.25x at five minutes, 2x at an hour) and a read costs a fraction of it. A one-hour
  write pays back on its second hit.
- Prefix order is fixed: tools, then system, then messages. A change anywhere invalidates
  everything from that byte onward.

So: constant content first — tool definitions, system instructions, long reference documents —
then the breakpoint at the end of the static block, then volatile content. Anything dynamic placed
before the static prefix (a timestamp, a session ID, a reordered tool list) breaks every cache
hit for every request.

Two non-obvious invalidators: changing `tool_choice` invalidates cached message blocks while
tools and system survive, and changing the output format configuration invalidates the thread's
cache.

## 3. Trim tool results before they enter history

A tool result is written into the conversation once and then re-sent on every subsequent request.
A 9,000-token response you needed four fields from costs you those 9,000 tokens for the rest of
the session.

Trim at the boundary — ideally in a `PostToolUse` hook that rewrites the tool output, so it
happens in one place for every caller. Cap tool responses; for calibration, Claude Code warns
above 10,000 tokens of MCP tool output and caps at 25,000 by default. And have upstream agents
return structured data — facts, citations, scores — rather than verbose reasoning.

## 4. Pin transactional facts in a never-summarized block

Extract amounts, dates, order numbers, IDs, and statuses into a structured block included in
every prompt, and never let it be summarized. In a multi-issue session, give each issue its own
entry.

Progressive summarization is the wrong tool for transactional data. It deletes precisely the
values the agent needs to act, and it does so silently. Summarize narrative; pin facts.

## 5. Put key findings at the top of long inputs

Models under-weight the middle of long inputs. Any aggregated input should lead with a key
findings summary and use explicit section headers below it. The same applies to a SKILL.md or a
reference file: the most important instruction goes near the top, because truncation takes the
tail.

## 6. Use the platform's context controls rather than improvising

- **Context editing** is configured with a `context_management` parameter carrying an `edits`
  array of typed entries. The tool-clearing edit clears the *oldest* tool results in
  chronological order, replacing them with a placeholder while preserving message structure and,
  by default, the tool call parameters. It supports a trigger threshold, a minimum amount to
  clear, a count of recent results to keep, and a list of tools to exclude. A second edit type
  clears thinking blocks. Clearing invalidates cached prefixes containing what it cleared, so
  pair it with a stable static prefix.
- **Auto-compaction** in Claude Code and the Agent SDK clears older tool outputs first, then
  summarizes. It is tunable through settings and an environment variable, and `PreCompact` /
  `PostCompact` hooks let you snapshot or re-inject state around it. You can instruct what to
  preserve — for example, always keeping the full list of modified files.
- **Compact, clear, or start fresh?** Compact when the thread is still on-task and you want
  continuity. Clear when switching tasks inside one session. Start fresh with summary injection
  when files on disk changed or the agent has lost grip on specifics. Resuming into stale tool
  results is the failure mode.

The tell for degradation, before you hit any limit: the agent says "this follows the typical
pattern" instead of naming the class or method it found earlier.

## 7. Push token-heavy orchestration out of the window

Two features exist specifically to keep volume out of context:

- **Deferred tool definitions plus a tool search tool** — removes the long tail of definitions
  from the prefix (a reported 85%+ of definition tokens) while keeping three to five hot tools
  resident and cacheable.
- **Programmatic tool calling** — Claude chains your tools inside code execution, so intermediate
  results never enter context and are not billed as input or output tokens. Roughly 20–40% fewer
  billed input tokens in the 10–49 tool-definition range.

A bigger window is the last option, not the first. Very large windows are real and usable, with a
pricing tier change above a documented threshold — but reach for them after the structural fixes,
and never as a repair for diluted attention.

## 8. Route by latency tolerance

**Synchronous** for anything where a human or a pipeline is waiting: pre-merge CI, interactive
review, live support.

**The Message Batches API** for latency-tolerant volume: overnight reports, weekly audits, bulk
extraction. The constraints that actually matter:

| Constraint | Value |
| --- | --- |
| Max per batch | 100,000 requests or 256 MB, whichever comes first |
| Completion | Usually under an hour; results available when all complete, or at 24 hours |
| Expiry | Batches expire at 24 hours |
| Result retention | Downloadable for 29 days from creation |
| Discount | 50% on both input and output |
| `custom_id` | `^[a-zA-Z0-9_-]{1,64}$`, unique within the batch |
| Not supported | Streaming, zero max tokens |
| Result order | **Not guaranteed** — correlate by `custom_id` |

Contrary to common belief, a batch item does support vision, tool use including server tools,
system messages, multi-turn conversations, extended thinking, and structured outputs. The batch
worker runs the same server-side agentic loop as the synchronous API. If a result comes back
paused, the turn is unfinished — continue it by submitting the paused assistant content in a
follow-up request. Client-side tool loops are the exception: a `tool_use` stop in a batch item is
a result you must answer with a new request, so genuinely interactive client-tool loops belong on
the synchronous API.

In practice: refine the prompt on a five-to-ten item sample first, then submit the full batch;
resubmit only failures by `custom_id`, with modifications such as chunking oversized inputs or
adding format-specific examples. Work SLAs backward from the 24-hour maximum. Prompt caching does
apply in batches, and the one-hour TTL is often the right choice there.

## Audit checklist

- [ ] Check cache-read token counts on a live request. Near zero on repeat calls means dynamic
      content is sitting before the static prefix.
- [ ] Nothing volatile — timestamp, session id, user name, reordered tools — sits above the last
      breakpoint.
- [ ] No more than four breakpoints, and the static prefix clears *your model's* minimum.
- [ ] TTL is chosen deliberately; one hour only where a second hit within the hour is likely.
- [ ] No tool result enters history untrimmed; you know the largest one in tokens.
- [ ] There is a token ceiling on tool responses at all.
- [ ] Transactional facts survive summarization and compaction verbatim.
- [ ] In long aggregated inputs, critical findings are in the first screen.
- [ ] Context editing or an auto-compaction window is configured rather than left to fill up.
- [ ] No code path resumes into stale tool results after files changed.
- [ ] Tool definitions over roughly 10k tokens use deferred loading.
- [ ] No latency-tolerant bulk workload runs synchronously at full price, and no blocking
      workload runs through batch.
- [ ] Batch results are correlated by `custom_id`, and paused results are continued.
- [ ] The batch prompt was validated on a small sample first.

## Patterns that hold up

**Cache-friendly ordering with the breakpoint at the static boundary.**

```python
response = client.messages.create(
    model=MODEL,
    max_tokens=4096,
    tools=TOOLS,                                  # stable: same order, same content, every call
    system=[
        {"type": "text", "text": SYSTEM_INSTRUCTIONS},
        {"type": "text", "text": POLICY_HANDBOOK,
         "cache_control": {"type": "ephemeral", "ttl": "1h"}},   # ends the static block
    ],
    messages=[*history, {"role": "user", "content": latest_turn}],   # volatile, after the prefix
)
```

Everything above the breakpoint is byte-identical across requests, so every call after the first
reads cheaply. The one-hour write pays for itself on the second hit and survives a slow human in
the loop.

**A case-facts block that is never summarized.**

```json
{ "caseFactsBlock": {
  "customerId": "C-4421",
  "issues": [
    { "id": "I-1", "orderId": "#8891", "orderDate": "2026-03-03",
      "chargeCount": 3, "refundAmount": "247.83 GBP", "status": "pending_refund" },
    { "id": "I-2", "orderId": "#8903", "orderDate": "2026-03-09",
      "issue": "wrong_size_shipped", "status": "replacement_offered" } ] } }
```

Injected verbatim into every prompt and explicitly excluded from any summarization instruction.
After four rounds of summarization the narrative may degrade freely, but the agent still knows it
owes 247.83 on order #8891 rather than "roughly two hundred."

**Trimming at the tool boundary, once.**

```js
// PostToolUse: a 9,400-token payload becomes ~120 usable tokens
function postToolUse(input) {
  if (input.tool_name !== "search_tickets") return;
  const r = JSON.parse(input.tool_response);
  return { hookSpecificOutput: { hookEventName: "PostToolUse",
    updatedToolOutput: JSON.stringify({
      total: r.total_count,
      returned: r.results.length,
      truncated: r.total_count > r.results.length,
      tickets: r.results.slice(0, 10).map(t => ({
        id: t.id, subject: t.subject, status: t.status,
        updated: new Date(t.updated_at).toISOString().slice(0, 10),
      })),
      hint: r.total_count > 10
        ? `10 of ${r.total_count} shown. Narrow with status= or updated_after= rather than paging.`
        : undefined,
    }) } };
}
```

The saving compounds, because the trimmed result is re-sent on every subsequent request. The hint
steers the agent toward targeted searches instead of pagination sprawl.

**Key findings first.**

```markdown
# Key findings (read first)
1. Refund path has no idempotency key -> duplicate charges possible (src/refund.ts:74) — CRITICAL
2. Session IDs generated from Math.random() (src/session.ts:88) — HIGH
3. 11 lower-severity findings, listed under "All findings" below

## Scope and method
## All findings
## Files reviewed
```

The two things that must not be missed sit in the first sixty tokens, above the region where
attention thins and above any truncation point.

**Context editing plus a stable prefix for a long tool-heavy session.**

```python
response = client.messages.create(
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
            "keep": {"type": "tool_uses", "value": 3},     # never clear the 3 most recent
            "exclude_tools": ["get_case_facts"],           # this result must survive
        }],
    },
    messages=messages,
)
```

The oldest results — the ones already acted on — clear automatically while message structure and
call parameters survive. Because cleared content sits after the static prefix, tools and system
keep hitting cache.

**Sample, batch, resubmit only failures.**

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

// 3. resubmit only what failed, modified
const failed = results.filter(r => r.result.type !== "succeeded").map(r => r.custom_id);
```

## Failure modes

**Dynamic content before the static prefix.**

```python
system=[
    {"type": "text", "text": f"Current time: {datetime.now()}. Session: {uuid4()}"},   # breaks everything
    {"type": "text", "text": LONG_POLICY_DOC, "cache_control": {"type": "ephemeral"}},
]
```

The first block changes on every request, so the cached prefix never matches and you pay the
write premium for a cache you never read. This is the single most common caching bug and it is
invisible unless you inspect cache-read token counts.

**Progressive summarization of transactional data.** Round one: "Customer C-4421 charged three
times 247.83 on order #8891, refund pending." Round four: "Customer has a billing issue involving
duplicate charges that is being resolved." The agent can no longer issue the refund, so it either
asks the customer to repeat what they already said or confabulates a figure.

**Raw payloads into history, then a bigger window as the fix.** The cost is
per-request-for-the-rest-of-the-session, so a handful of fat results dominates the bill and
dilutes attention. A bigger window makes the same waste affordable for longer.

**Pre-loading everything "so the agent has it."** Reading 340 files into one message inverts
just-in-time retrieval: the model must locate signal inside a huge low-signal block — exactly the
condition under which middle-of-input under-weighting bites — and you pay for all 340 whether or
not two mattered.

**Blocking work moved to batch for the discount.** There is no latency SLA and the batch may
legitimately take 24 hours. Fifty percent off is irrelevant next to a blocked merge queue.

**Assuming batch cannot do tools or multi-turn, or skipping the sample.** Teams either skip a
legitimate 50% saving on a false premise, or, having discovered it, submit 5,000 unsampled
prompts and receive 5,000 identically malformed results. Ignoring a paused result silently
truncates the work.

## Porting to other stacks

- **Any provider with prefix caching** — the layout rule is identical and provider-independent:
  immutable content first, volatile last, never reorder the stable part. Automatic caching still
  requires a stable prefix, so the dynamic-prefix bug bites the same way even where you do not
  place breakpoints yourself.
- **LangGraph and LangChain** — trimming belongs in the tool wrapper's return path, the analogue
  of a post-tool hook. Token-count-based message trimmers will happily drop the message holding
  your key facts, so pin facts in graph state rather than in the message list.
- **Server-managed thread APIs** — the platform hides context growth, so the failure mode is
  silent cost creep. Instrument per-turn input tokens explicitly and set your own trimming
  policy; do not assume the platform trims in your interest.
- **Batch equivalents** — every provider's batch tier trades latency for roughly half price
  inside a similar 24-hour envelope. Sample, submit, resubmit-only-failures transfers exactly, as
  does correlating by your own request id.

## Scope note

The minimum cacheable prefix and the cache-read multiplier are per-model values that change with
each model release, which is why this skill points at the documentation's table rather than
reproducing it. Auto-compaction's exact trigger threshold is a moving implementation detail —
configure the window explicitly rather than depending on the default. A filesystem-backed memory
of your own (a scratchpad, a project memory file, a manifest) is the durable pattern; do not
assume a particular managed memory tool exists in your runtime without checking.
