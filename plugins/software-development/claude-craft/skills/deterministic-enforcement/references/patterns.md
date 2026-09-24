# Enforcement patterns and failure modes

Read this when building subagent validation or when checking a design against the failure modes
below.

## Subagent lifecycle hooks as the validation boundary

A subagent returns one final message with no type checking. Validate that message once, centrally,
instead of in every coordinator prompt that consumes it:

- **`SubagentStart`**: log or rate-limit the spawn, and check that the required context was passed.
- **`SubagentStop`**: validate the returned output against its schema, strip sensitive data, and
  log completion.

A `Stop` hook declared in a subagent's own frontmatter is converted to `SubagentStop` when it
runs. Note that plugin-shipped agents ignore `hooks` in their frontmatter, so register these hooks
in the plugin's `hooks/hooks.json` instead:

```jsonc
// hooks/hooks.json
{ "hooks": {
  "SubagentStart": [{ "hooks": [{ "type": "command", "timeout": 10,
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/check-delegation.sh" }] }],
  "SubagentStop":  [{ "hooks": [{ "type": "command", "timeout": 10,
    "command": "\"${CLAUDE_PLUGIN_ROOT}\"/scripts/validate-findings.sh" }] }]
} }
```

## Failure modes

**A prompt as the control for a financial or security operation.** Instructions like "Always verify
identity before processing a refund" or "Never run destructive commands without asking", and
capitalized limits, only shift probabilities. Emphasis does not change that. Keep the prompt as
documentation of the gate, not as the gate itself.

**PostToolUse as the blocker.**

```js
if (input.tool_name === "process_refund" && input.tool_input.amount > 500) {
  return { decision: "block", reason: "over limit" };   // the money has already moved
}
```

This hook fires after the refund has run, and `decision: "block"` only attaches a note to the
result. What you have built is an audit trail of violations you failed to prevent.

**A gate that fails open without anyone noticing.** A slow PreToolUse command hook, such as one
that makes a network call, times out, and the tool call proceeds. The same happens when the script
path is wrong: Claude Code shows a non-blocking error, and the call runs anyway. Keep gates local
and fast, set `timeout`, and back each hook with a deny rule wherever a rule can express the policy.

**Few-shot examples or a reviewer subagent as the ordering control.** Few-shot examples raise
adherence, but 97% on a compliance gate is still a failed gate. A reviewer subagent is itself
probabilistic, and if it runs after the action it is just PostToolUse with extra steps. Keep
reviewers for judgement calls that have no deterministic form.

**Treating a hook allow as an override, or keeping safety rules in local settings.** Deny and ask
rules still apply after a hook allows a call. And deny rules that live only in an untracked
`settings.local.json` disappear on a fresh clone or in CI.

**Bypassing permissions outside a sandbox.** Running with every guardrail off, on a task whose
input may be untrusted (an issue body, a web page, a customer email), turns a prompt injection into
arbitrary command execution.
