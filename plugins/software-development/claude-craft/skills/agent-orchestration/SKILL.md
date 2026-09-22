---
name: agent-orchestration
description: "Designing coordinator and subagent systems: whether delegation earns its token multiplier, hub-and-spoke routing, decomposition as the owner of coverage, writing agent descriptions that drive selection, passing complete context into an isolated subagent, parallel spawning, choosing resume vs. fork vs. a fresh session, per-item passes plus an integration pass, and independent review. Use when building or reviewing a multi-agent workflow, when output has topic-shaped gaps or uneven depth, or when deciding how to continue work after files changed. Not for the message loop itself or for caching and compaction."
license: MIT
---

# Agent orchestration

Published measurement from Anthropic: a single agent uses roughly 4x the tokens of a chat
interaction, and a multi-agent system roughly 15x. That multiplier is the price of admission.
Earn it or do not pay it.

Keep one diagnostic habit above all others: decomposition failures masquerade as subagent
failures. When the output is wrong, trace back to where the work was split before you change
anything downstream.

## 1. Delegate for breadth or isolation — not for sophistication

Spawn subagents when the work is genuinely parallel across independent subtasks (breadth-first
research, per-file review, multi-source gathering), or when verbose investigation would otherwise
flood the coordinator's window.

Do not spawn when:

- the task is single and focused — the overhead buys nothing;
- the work depends on deep shared context, since rebuilding it inside each isolated window costs
  more than the fan-out saves;
- latency matters more than throughput.

One agent with good tools beats a multi-agent system on most tasks. Reach for delegation only
when you can say the independent subtasks out loud.

## 2. Hub and spoke

One coordinator decomposes the task, selects subagents, passes context, aggregates results, and
owns error handling. Route all inter-agent information through it — that is what buys
observability, uniform error handling, and controlled context flow.

Nested delegation exists, with a depth limit that has moved between releases; do not build on a
specific depth. Keep any tree shallow and explicit, and route cross-branch information through a
parent.

Do not wire subagents to each other for efficiency. You lose the only vantage point from which a
coverage gap is visible.

## 3. Decomposition owns coverage

Missing scope — whole topics absent from the output — is almost always the coordinator's split.
It is not the subagents, not the search queries, not the agent count.

```text
Good:  "impact of AI on creative industries" -> [visual arts, music, writing, film, games]
Bad:   "impact of AI on creative industries" -> [visual arts]
```

Run iterative refinement: evaluate the synthesis for gaps and re-delegate until coverage is
sufficient. A single-pass fan-out has no mechanism for noticing what it never asked about.

## 4. Descriptions are for selection; prompts are for goals

The `description` is the selection mechanism. Claude matches the request against every available
agent's description, so it must say what the agent does **and when to invoke it**, including when
not to. Vague descriptions cause silent misrouting that reads like a capability gap.

The subagent's `prompt` is its system prompt: scope it to the role and restrict `tools` to match.
Coordinator prompts should specify goals rather than procedures — subagents choose their own path,
and over-specified steps waste tokens and suppress better strategies.

The `AgentDefinition` surface (SDK `options.agents`) carries `description`, `prompt`, and
optionally `model`, `tools`, `disallowedTools`, `skills`, `maxTurns`, `effort`, `mcpServers`,
`initialPrompt`, `background`, `memory`, and `permissionMode`. There is no `name` field — the name
is the key in the `agents` record, or frontmatter `name` / the filename under `.claude/agents/`.
`model` accepts an alias or a full model ID. `disallowedTools` is applied first and `tools`
resolves against the remainder, so a tool listed in both is removed. Plugin-provided agents are
namespaced `<plugin>:<agent>`, and project or user definitions override same-named plugin agents.
Verify this list against current SDK docs before depending on a specific field.

## 5. The prompt is the only channel in; the final message is the only channel out

The only content that crosses from parent to subagent is the spawn prompt, and the only thing
that comes back is the subagent's final message. The subagent does not see the parent's
conversation, the files the parent read, or any prior subagent's results. It does get its own
system prompt, tool definitions, and project-level configuration — none of which carry your task
context. A fork-style subagent is the one exception; it inherits the parent conversation by
design.

Therefore:

- Pass every fact the subagent needs, in full, in the prompt. Never assume it can look something
  up from prior results.
- Pass findings as structured data that keeps content and metadata together. Content stripped of
  its source metadata is exactly what produces unsourced synthesis downstream — the defect lives
  in the context passing, not in the synthesis agent.
- The filesystem is the only other honest channel: have one subagent write a report to a path and
  tell the next to read that path.

Spawning capability is gated by the agent's own `tools` list, not by an auto-approve list. Omit
the spawn tool from `tools` and the agent cannot delegate at all. An auto-approve list only
suppresses prompts; unlisted tools fall through to the permission mode rather than being blocked,
so adding the spawn tool there grants nothing it did not already have.

## 6. Parallelize independent work; pick the session strategy by what changed

Independent subagents should run at the same time, not one per turn — sequential spawns serialize
latency for no benefit. In practice this means issuing the spawns together rather than waiting on
each result. There is a documented concurrency cap (20 subagents at time of writing). Read-only
work parallelizes cleanly; stateful work (writes, edits, shell) should not run concurrently
against the same files.

| Situation | Use |
| --- | --- |
| Continuing work, files unchanged | Resume the session |
| Comparing alternatives from one baseline | Fork the session |
| Rewinding to a specific earlier point | Resume at a message UUID |
| **Files changed, or context degraded** | **Fresh session plus summary injection** |

After files change, resuming is a trap: stale tool results stay in history and keep biasing
reasoning, so the agent recommends fixes already applied and cites deleted code. Start fresh,
inject a structured summary of prior findings, name the changed files, and re-analyze only those.

## 7. Fix uneven depth with structure, not with a bigger window

The symptom: thorough on early items, shallow on later ones; a pattern flagged in one file and
ignored in the next. That is attention dilution, and it is structural. The fix is a multi-pass
architecture — one focused pass per item, then a separate cross-item integration pass for data
flow, consistency, and contradictions.

A larger context window does not fix it. The constraint is attention quality, not window size.

Match the decomposition pattern to the task:

- **Fixed sequential pipeline** — predictable structured work: multi-file review, document
  processing, extraction, compliance checks. Consistent and debuggable.
- **Dynamic adaptive decomposition** — open-ended work of unknown scope: legacy exploration,
  security audits, research, debugging unfamiliar systems. The plan evolves as you learn.

Choosing the dynamic pattern for predictable work is the most common over-engineering here.

## 8. Review with a fresh instance; explore with a scratchpad

A separate instance with no prior reasoning context will challenge decisions the generating
session would defend. Asking the same session to "now review your code" retains generation bias
and mostly produces ratification.

For extended exploration, maintain a scratchpad file from the start. Write concrete findings —
classes, paths, dependency chains, coverage — and read it back instead of relying on conversation
context. Delegate verbose investigation to subagents that return structured summaries, inject
phase-1 summaries into phase-2 prompts, compact proactively, and persist a crash-recovery
manifest: explored paths, key findings, current phase, next steps.

The tell for context degradation is the agent saying "this follows the typical pattern" instead
of naming the concrete class or method it found earlier.

## Audit checklist

- [ ] You can name the independent subtasks that justify the token multiplier.
- [ ] Every subagent description says when to use it and when not to.
- [ ] The coordinator's `tools` list actually includes the spawn tool.
- [ ] Subagent `tools` are scoped to the role rather than everything.
- [ ] No subagent prompt references information the subagent was never given ("the findings
      above", "as established earlier", "the file you read").
- [ ] Findings crossing an agent boundary carry source metadata.
- [ ] Independent spawns are issued together, not one per turn.
- [ ] No code path resumes a session after files on disk changed.
- [ ] Multi-item work has one pass per item plus a separate integration pass.
- [ ] Generated output is reviewed by a fresh instance.
- [ ] Long explorations keep a scratchpad and read it back.
- [ ] When output has a coverage gap, debugging starts at the decomposition.

## Patterns that hold up

**Role-scoped subagents with disambiguating descriptions.**

```ts
const agents = {
  "source-gatherer": {
    description:
      "Gathers primary sources on one narrow subtopic and returns findings with full " +
      "provenance (url, document name, page, excerpt, retrieval date). Invoke once per " +
      "subtopic, in parallel. Do NOT use for synthesis or cross-source reconciliation.",
    prompt: SOURCE_GATHERER_PROMPT,
    tools: ["WebSearch", "WebFetch", "Write"],
  },
  synthesizer: {
    description:
      "Merges gathered findings into a cited report, preserving every claim-to-source " +
      "mapping and annotating conflicts rather than resolving them. Invoke once, after " +
      "all gathering completes. Do NOT use to fetch new sources.",
    prompt: SYNTHESIZER_PROMPT,
    tools: ["Read", "Write"],          // deliberately no search tool
  },
};
```

Each description says what, when, and when-not, so selection is decided by the roster rather than
by luck. Tool scoping makes the synthesizer structurally incapable of quietly re-researching
instead of synthesizing.

**A spawn prompt that assumes nothing shared.**

```text
Subtopic: AI in music production.
Scope: 2023-2026 only. Exclude consumer music generation.
Output: JSON array of findings, each with claim, source_url, document_name,
  page_number (if paginated), excerpt, publication_date, confidence.
Write the array to ./research/music.json and return only a five-line summary.
Context you need: this report frames "creative industries" as professional practice,
  not hobbyist tooling. An earlier phase established that "generative" is ambiguous here —
  always disambiguate to "generative composition" or "generative mastering".
```

Scope, output contract, file path, and the one piece of inherited judgement all travel in the
prompt. The summary-only return keeps the coordinator's window clean while the full data lands on
disk.

**Per-item passes plus an integration pass.**

```js
const perFile = await Promise.all(files.map(reviewOneFile));  // full attention each
const integration = await reviewCrossFile(perFile);           // data flow, contradictions
```

The integration pass is the only place that needs the whole picture, and it operates on
structured summaries rather than raw files, so it stays small.

**Fresh session with summary injection after files changed.**

```text
Prior analysis found issues in auth.ts, session.ts, and middleware.ts:
  - auth.ts:142 — token compared with == instead of a constant-time compare   [FIXED]
  - session.ts:88 — session id generated from Math.random()                   [FIXED]
  - middleware.ts:31 — CORS wildcard with credentials: true                   [FIXED]
All three have since been modified. Re-analyze only those three files: verify each
fix is correct and check for regressions introduced by the change.
```

**A scratchpad holding specifics outside the window.**

```markdown
# Exploration scratchpad — Order Service   (phase 2 of 3)
## Established
- OrderRepository (src/repos/order.ts) implements Repository<T>; custom findById caching
- Chain: RefundProcessor -> OrderService -> OrderRepository -> PostgreSQL
- CRITICAL: RefundProcessor has no retry around the payment call (src/refund.ts:74)
## Explored
src/repos/**, src/services/order*.ts, src/refund.ts
## Not yet explored
src/webhooks/**, migrations/
## Next
Trace the webhook replay path; confirm the idempotency key is persisted before the payment call.
```

Concrete names survive compaction, a crash, or a fresh session. Recovery is one read instead of a
re-exploration.

## Failure modes

**Narrow decomposition, then blaming the subagents.** Split to `[visual arts]`, then rewrite the
search queries, upgrade the subagent model, add more visual-arts agents. Music, writing, and film
were never requested, so no downstream change can find them — and the output looks complete
because nothing reports a gap.

**Assuming shared memory.** "Synthesize the findings from the research agents" reaches a
synthesizer that has never seen them. It reports nothing, or worse, generates plausible findings
from parametric knowledge and produces a confident unsourced report. Pass the findings, or the
paths they were written to.

**Content passed without metadata.** "Solar panel efficiency rose 25% in a decade" cannot be
cited by an agent that was never told where it came from. Teams then pressure the synthesis agent
to add citations, which produces fabricated ones.

**Peer-to-peer subagents, or sequential spawns.** The first destroys the coordinator's vantage
point — no single place knows what was covered or what failed. The second pays full serialization
latency for work with no dependencies.

**Resuming after code changed, or reviewing in the generating session.** The resumed session still
holds pre-fix file contents in tool results and reasons from them. The same-session review shares
the reasoning that produced the code and defends it.

**One pass over fourteen files, then reaching for a bigger window.** The defect is attention
dilution across items in a single pass; more window gives the same diluted attention more room.

## Porting to other stacks

- **LangGraph** — the coordinator is a supervisor node; keep worker-to-worker edges out of the
  graph so all transitions pass through it. Context isolation is not automatic — workers share
  graph state by default, so scope what each worker reads or you lose the isolation that
  justified the fan-out. Parallelism comes from a fan-out edge.
- **CrewAI and AutoGen** — these default to agent-to-agent chatter, which is exactly the
  antipattern above. Configure a hierarchical process and forbid peer delegation. Shared-memory
  features tempt you to skip explicit context passing; the metadata-stripping failure shows up
  identically if you do.
- **Handoff-style frameworks** — a handoff transfers the conversation rather than returning to a
  hub, so coverage tracking has no natural home. Add an explicit orchestrator that owns the
  subtask list and have each agent hand back to it rather than onward to a peer.
- **Universal** — descriptions drive selection, isolated context needs complete prompts, per-item
  passes plus integration, and independent review are properties of LLMs rather than of any SDK.

## Scope note

Parallel subagents and the concurrency cap are documented; the exact launch mechanism (multiple
spawn calls in one assistant message) is how it works in practice rather than a documented
contract, so do not build tooling that depends on the message shape. Nested-subagent depth limits
have changed across releases. Persistent-subagent messaging is gated behind experimental flags in
some builds — treat every spawn as fresh unless you have verified otherwise in your own version.
