---
name: deterministic-enforcement
description: "Enforcing agent behavior in code instead of in prompts: choosing enforcement by the blast radius of one failure, PreToolUse gates and permission decisions, PostToolUse result rewriting and why it cannot block, the hook event and hook type surface, permission rule syntax and deny-ask-allow evaluation order, settings precedence, sandboxing autonomous agents, and writing a self-contained human handoff. Use when a tool must not run before a prerequisite, when a policy or spend limit has to hold every single time, or when writing hooks, permission rules, or sandbox configuration. Not for tool schema design or for escalation triggers."
license: MIT
---

# Deterministic enforcement

Prompts raise probability. Gates reach certainty. The whole skill is knowing which one a
requirement deserves, and then implementing the gate correctly.

Safety, compliance, and financial correctness always get programmatic enforcement. Nothing in any
other design guidance overrides that.

## 1. Choose enforcement by the blast radius of one failure

| A single failure would cause | Use |
| --- | --- |
| Financial loss, security breach, data loss, compliance violation | **Programmatic enforcement** — a hook, a permission rule, a prerequisite gate |
| Only a formatting, style, ordering, or tone deviation | **Prompt-based guidance** |

There is no third option called "a stronger prompt." "Always verify identity before a refund" in
a system prompt fails a non-zero percentage of the time, forever, and the failures are exactly
the cases you wrote the instruction for.

Ask: if this instruction is ignored once, what is the worst outcome? That answer picks the row.

## 2. Prerequisite gates live in code and read session state

A gate is a function of session state, not of the model's intent. A refund tool cannot run until
an identity lookup has returned a verified customer ID *in this session*. Implement it in a
`PreToolUse` hook or a permission callback, keyed off state your code owns.

A gate must do three things: block, say **why** in terms the agent can act on, and name the
prerequisite call. A bare "denied" leaves the agent guessing and burning turns.

## 3. PreToolUse enforces; PostToolUse normalizes

```text
PreToolUse  -> BEFORE execution -> allow / deny / ask / defer; may rewrite the input
PostToolUse -> AFTER  execution -> rewrite the result; blocks nothing
```

**PreToolUse** returns, inside `hookSpecificOutput`, a `permissionDecision` of `allow`, `deny`,
`ask`, or `defer`, a `permissionDecisionReason`, and optionally `updatedInput` to rewrite
arguments or `additionalContext`. When several hooks respond, precedence runs
deny > defer > ask > allow. Command-form hooks can also block with exit code 2 plus stderr.
Top-level decision and reason fields are deprecated for this event — use `hookSpecificOutput`.

**PostToolUse cannot block anything.** Returning a block decision does not stop the next turn — it
attaches the reason next to the tool result as feedback, and Claude still sees the original
output. Exit code 2 is likewise non-blocking here. What PostToolUse *can* do is rewrite the result
(`updatedToolOutput`, or the MCP variant) and add context, which makes it the right place to
normalize data before the model sees it — dates to ISO 8601, status codes to labels, consistent
currency — and to trim verbose payloads.

Using PostToolUse to block a policy violation is the single most common hook antipattern. By the
time it fires, the refund is issued, and the "block" you returned was only a comment.

Top-level fields available on hook output regardless of event include `continue`, a stop reason,
a system message surfaced back to Claude, a terminal sequence, and an output-suppression flag
that the documentation notes is accepted but not acted on.

## 4. Hooks are a large surface, and a shell command is only one of five types

The event list is much broader than the two above. Documented events span session lifecycle
(`SessionStart`, `Setup`, `SessionEnd`), prompt handling (`UserPromptSubmit`,
`UserPromptExpansion`), tool flow (`PreToolUse`, `PermissionRequest`, `PermissionDenied`,
`PostToolUse`, `PostToolUseFailure`, `PostToolBatch`), subagent and task lifecycle
(`SubagentStart`, `SubagentStop`, `TaskCreated`, `TaskCompleted`), turn control (`Stop`,
`StopFailure`, `TeammateIdle`), environment changes (`ConfigChange`, `CwdChanged`,
`DirectoryAdded`, `FileChanged`, worktree events), compaction (`PreCompact`, `PostCompact`), model
switching, elicitation, and display notifications. Availability varies by SDK and version —
verify against your own build before depending on one.

Hook types: `command` (shell, JSON on stdin and stdout), `http` (POST to an endpoint),
`mcp_tool`, `prompt` (send the hook input to a small model and let it decide), and `agent`
(delegate to a subagent). Reaching for a command hook when a prompt hook would do is fine;
reaching for a prompt hook when a deterministic rule would do defeats the point of a gate.

**Subagent lifecycle.** `SubagentStart` is where you log or rate-limit a spawn and verify required
context was actually passed. `SubagentStop` is where you schema-validate the returned output,
strip sensitive data, and log completion. A `Stop` hook declared in a subagent's own frontmatter
is converted to a `SubagentStop` event at runtime.

Footguns:

- Hooks have a timeout; set it per entry.
- **The matcher switches between literal and regex based on its characters.** `*`, an empty
  string, or omission matches everything. If it contains only letters, digits, underscore,
  hyphen, spaces, commas, and pipes, it is exact string matching split on pipes or commas. Any
  other character makes it an unanchored JavaScript regex — so `mcp__memory__.*` and `^Notebook`
  work, and a stray `.` or `(` silently changes the semantics. Some events use a narrower exact
  character set.
- Exit code 2 blocks for most events; other non-zero codes generally do not, except worktree
  events which fail on any non-zero exit. JSON on stdout is parsed on every exit code, and on a
  non-2 code a valid decision object overrides the code.
- Every hook in a batch must return before the turn continues, so keep them fast.

## 5. Permission rules are the other half, and a hook allow does not bypass them

Evaluation is first-match-wins, in this order:

1. **Deny** rules — enterprise-managed denies, disallowed tools, explicit deny entries.
2. **Ask** rules — always prompt when matched.
3. **Allow** rules — allowed tools, explicit allow entries.
4. The permission mode's default for whatever is left.

A PreToolUse hook returning `allow` does not skip the deny and ask rules beneath it. Treat hooks
and rules as complementary, not as an override chain. A permission callback fires only when
evaluation lands on "prompt" — pre-approved tools never reach it.

Rule syntax looks like `Bash(npm run test:*)`, `Read(//absolute/path)`, bare `Edit`, and MCP tools
as `mcp__<server>__<tool>` (plugin-bundled servers carry a longer prefix). Wildcard placement
differs by rule type: **allow** rules accept a glob only after a literal, glob-free
`mcp__<server>__` prefix, while **deny** and **ask** rules accept broader forms such as `mcp__*`.
Hook matchers go further and accept a regex in the server segment. So you can broadly deny MCP,
but you must enumerate servers to broadly allow.

Settings precedence, highest first: enterprise-managed settings, then CLI arguments, then
project-local settings, then project settings, then user settings. Two caveats: list-valued keys
**merge** across tiers rather than override, and a few security-sensitive keys honor a stricter
lower-level value. Anything you rely on for safety belongs at the managed or project tier, not in
a local file a developer can edit away.

## 6. Match permission mode to autonomy, and put autonomy inside a sandbox

Modes range from the default manual mode (prompt for anything not pre-approved), through
edit-accepting and plan-only modes, to modes that stop asking entirely and, at the far end,
near-total autonomy. The don't-ask mode is the one to reach for in headless and CI contexts, where
a prompt has nobody to answer it.

Bypass-permissions mode and the dangerous skip flag are acceptable **only inside a sandbox**,
never as a way to make prompts stop appearing on a production path. The sandboxed shell tool
provides OS-level filesystem and network confinement: read and write allowlists and denylists,
domain allowlists and denylists, and a strict-allowlist switch that denies hosts outside the
allowlist instead of prompting. That is process-level confinement, not VM-grade isolation —
secrets still need explicit exclusion.

Recommended posture for an autonomous agent: sandbox on, explicit filesystem allowlist, strict
network allowlist, deny rules for credential paths, and a disallowed-tools list for anything that
must never run regardless of mode.

## 7. Decompose multi-concern requests; hand off self-contained

Handle a request carrying several distinct issues by decomposing into separate items,
investigating them in parallel with shared context, and returning one unified resolution — not
three disconnected answers.

Every human handoff must be self-contained, because the human does not see the transcript.
Include the record or customer ID, a summary of the conversation, root-cause analysis, the amount
at stake if any, what was already attempted, and a recommended action. A handoff that says
"escalating, see above" is not a handoff.

## Audit checklist

- [ ] List every system-prompt instruction beginning with "always", "never", or "must". For each,
      if ignored once, is the worst outcome financial, security, data-loss, or compliance? Each
      yes is a missing gate.
- [ ] No tool-call *ordering* requirement is enforced only by prose or few-shot examples.
- [ ] No PostToolUse hook returns a block decision believing it prevents something.
- [ ] Result-rewriting hooks use the documented field name, not an invented one.
- [ ] Deny reasons name the prerequisite call rather than just refusing.
- [ ] No threshold gate leaves the split-the-transaction workaround open.
- [ ] Hook timeouts are set, and command hooks use exit 2 to block.
- [ ] No matcher contains a character outside the literal set unless a regex was intended.
- [ ] Subagent output is validated at `SubagentStop` rather than trusted as-is.
- [ ] Safety-relevant permission rules live in managed or project settings, not a local file —
      remembering that list-valued keys merge across tiers.
- [ ] Bypass modes are never used outside a sandbox.
- [ ] A strict network allowlist is set for any agent acting on untrusted input.
- [ ] Headless and CI runs use the don't-ask mode rather than bypass.
- [ ] Escalations contain everything a reviewer needs, with no reference to "the conversation
      above."

## Patterns that hold up

**A prerequisite gate in PreToolUse.**

```js
function preToolUse(input, session) {
  if (input.tool_name === "process_refund" && !session.verifiedCustomerId) {
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          "Refund blocked: identity not verified in this session. Call get_customer with the " +
          "customer's email, phone, or customer ID first, then retry process_refund.",
      },
    };
  }
}
```

The gate is a pure function of state your code owns, so the model cannot talk its way past it,
and the reason tells the agent exactly how to become compliant, so it recovers in one turn.

**A threshold gate that routes instead of just refusing.**

```python
async def pre_tool_use(input, ctx):
    if input["tool_name"] != "process_refund":
        return None
    amount = Decimal(str(input["tool_input"].get("amount", 0)))
    if amount > Decimal("500"):
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"{amount} GBP exceeds the 500 GBP auto-approval limit. "
                "Create a manager approval request with create_approval_request "
                "(include order id, reason code, and the customer's stated issue). "
                "Do not attempt a smaller partial refund to stay under the limit."),
        }}
    return None
```

It closes the obvious workaround in the same breath as the denial, and names the compliant path.

**PostToolUse normalizing, not policing.**

```js
function postToolUse(input) {
  if (input.tool_name !== "lookup_order") return;
  const r = JSON.parse(input.tool_response);
  return { hookSpecificOutput: { hookEventName: "PostToolUse",
    updatedToolOutput: JSON.stringify({
      order_id:  r.orderNum,
      status:    STATUS_LABELS[r.st] ?? `unknown(${r.st})`,   // 3 -> "shipped"
      placed_at: new Date(r.ts_ms).toISOString(),             // epoch ms -> ISO 8601
      total:     `${(r.cents / 100).toFixed(2)} ${r.cur}`,    // 24783 -> "247.83 GBP"
      items:     r.li.map(i => ({ name: i.n, qty: i.q })),    // drop 11 unused fields
    }) } };
}
```

The model sees one consistent shape across every order source, and the normalization lives in one
place instead of being re-derived in each prompt. It doubles as a context saving.

**Subagent lifecycle hooks as the validation boundary.**

```js
hooks: {
  SubagentStart: [{ hooks: [{ type: "command",
    command: '"${CLAUDE_PLUGIN_ROOT}"/scripts/check-delegation.sh' }] }],   // required context present?
  SubagentStop:  [{ hooks: [{ type: "command",
    command: '"${CLAUDE_PLUGIN_ROOT}"/scripts/validate-findings.sh' }] }],  // schema + redaction
}
```

Subagents return a single final message with no type safety. Validating at stop catches a
malformed or over-sharing result once, centrally, instead of in every coordinator prompt that
consumes it.

**Autonomy fenced by a sandbox and deny rules.**

```json
{
  "permissions": {
    "deny":  ["Read(//**/.env*)", "Read(//**/.ssh/**)", "Bash(curl:*)", "mcp__*"],
    "allow": ["Read", "Grep", "Glob", "Edit", "Bash(npm run test:*)", "Bash(git diff:*)"]
  },
  "sandbox": {
    "enabled": true,
    "allowRead":  ["/workspace/repo"],
    "allowWrite": ["/workspace/repo"],
    "denyRead":   ["/workspace/repo/secrets"],
    "network": { "allowedDomains": ["registry.npmjs.org"], "strictAllowlist": true }
  }
}
```

The blast radius is bounded by the OS rather than by the agent's judgement, which is what makes
high autonomy affordable. Deny rules survive any permission mode.

**A handoff the human can act on without the transcript.**

```json
{
  "customer_id": "C-4421",
  "issue_summary": "Charged 3x for order #8891 on 2026-03-03; two duplicate charges of 247.83 GBP.",
  "root_cause": "Payment retry loop fired on a 504 from the processor; idempotency key absent (confirmed in logs 14:02-14:04 UTC).",
  "already_attempted": ["Verified identity via get_customer", "Confirmed 3 charges in lookup_order", "Refund blocked by the 500 GBP auto-approval gate"],
  "amount_at_stake": "495.66 GBP (two duplicate charges)",
  "recommended_action": "Approve the 495.66 GBP refund and file a processor-retry bug; the customer is owed both duplicates, not a goodwill credit.",
  "escalation_reason": "amount_over_auto_approval_limit"
}
```

Decision-ready: the reviewer does not reconstruct context, and the escalation reason is
machine-readable so you can audit how often each gate fires.

## Failure modes

**A prompt as the control for a financial or security operation.** "Always verify identity before
processing a refund", "Never run destructive commands without asking", and shouted capitalized
limits are all probability adjustments. Emphasis does not change that. Over thousands of sessions
the tail cases — ambiguous identity, an insistent user, an unusual phrasing — are the ones that
slip, and they are the expensive ones. Keep the prompt as documentation of the gate, not as the
gate.

**PostToolUse as the blocker.**

```js
function postToolUse(input) {
  if (input.tool_name === "process_refund" && input.tool_input.amount > 500) {
    return { decision: "block", reason: "over limit" };     // money already moved
  }
}
```

It runs after execution, and the block is not even a block — it attaches a note beside the tool
result while Claude still sees the successful refund. You have built an audit trail of violations
you failed to prevent and named it a control.

**Few-shot examples or a reviewer subagent as the ordering control.** Few-shot raises adherence
and adds tokens to every request, but 97% on a compliance gate is a failed gate. A reviewer
subagent is itself probabilistic, adds a full agent's latency and cost, and — if it runs after the
action — is PostToolUse with extra steps. Keep the reviewer for judgement calls that have no
deterministic form.

**Assuming a hook allow overrides everything, or hiding safety in local settings.** An allow from
a hook does not skip deny or ask rules, so a hook written as an override silently does nothing on
the tools that matter most. And deny rules living only in an untracked local settings file sit at
a low precedence tier and vanish on a fresh clone or in CI.

**Bypassing permissions outside a sandbox.** Running an agent with all guardrails removed on a
task whose instructions may come from untrusted input — an issue body, a web page, a customer
email — hands prompt injection arbitrary command execution.

**A handoff that assumes the human saw the conversation.** "I've escalated this to a human agent
who will review the details above" arrives in a queue with no ID, no amount, no root cause, and no
recommendation, so the reviewer re-runs the entire investigation — the cost the agent was supposed
to remove.

## Porting to other stacks

- **LangGraph** — a gate is a conditional edge plus a validator node, and prerequisite state lives
  in the graph state object. The equivalent mistake is putting the check inside the tool node's
  body after the side effect; validate on the edge *into* the node.
- **OpenAI Agents SDK** — input and output guardrails are the closest analogue to PreToolUse and
  a subagent-stop validator. The blast-radius rule decides guardrail versus instruction
  identically. There is no layered allow/ask/deny rule engine, so you own the precedence logic —
  write it once, first-match-wins, so it stays auditable.
- **Anywhere** — the deterministic core is a function of session state that runs before the side
  effect, returns a reason, and cannot be reached by the model. If your framework lacks a hook
  point, put the gate in the tool wrapper's first lines, before any I/O. Sandboxing is an OS
  concern and transfers unchanged: containers, seccomp, egress allowlists.

## Scope note

The hook event surface differs between SDKs and the CLI, and it has grown fast — verify the events
you depend on against your installed version rather than against the list here. Documentation has
also described the permission evaluation order slightly differently in different places, notably
on where the permission mode sits relative to allow rules; when the distinction matters for a
control, test it rather than reasoning from a page. Documented fallback behavior when a hook
itself times out or throws is thin, so design gates to fail closed in your own wrapper.
