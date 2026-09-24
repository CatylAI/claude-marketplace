# Porting enforcement to other stacks

Read this when the agent is not built on Claude Code or the Claude Agent SDK. Framework features
change quickly, so check each one against that framework's current documentation.

- **Graph-based orchestrators.** Put the gate on the conditional edge that leads into the tool
  node, not inside the node's body after the side effect has run. Keep the prerequisite state in
  the graph state object.
- **SDKs with input and output guardrails.** Guardrails are the nearest equivalent to PreToolUse
  and a subagent-stop validator, and the blast-radius rule decides between guardrail and
  instruction in the same way. Where there is no layered allow/ask/deny engine, write the precedence
  logic yourself, once, as first-match-wins, so it stays auditable.
- **Any framework.** The deterministic core is a function of session state. It runs before the
  side effect, returns a reason, and sits where the model cannot reach it. If there is no hook
  point, put the gate in the first lines of the tool wrapper, before any I/O. Sandboxing is an OS
  concern and carries over unchanged: containers, seccomp, and egress allowlists.
