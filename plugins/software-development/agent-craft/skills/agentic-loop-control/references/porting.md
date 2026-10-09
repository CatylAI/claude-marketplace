# Porting loop control to other stacks

> **Verify against current docs.** Other frameworks' field names and defaults change; confirm them
> in that framework's own documentation.

These are control-flow rules, not SDK rules.

- **LangGraph and other state machines.** The conditional edge out of the model node reads the raw
  stop reason off the response, not a parsed field or a regex over content. Put the cap on
  `recursion_limit` and treat hitting it as a graph error, not a terminal state.
- **OpenAI-style loops.** `finish_reason` covers less ground (`stop`, `tool_calls`, `length`,
  `content_filter`). `length` is the `max_tokens` analogue; there is no `pause_turn` equivalent, so
  checkpointing long server-tool turns is yours to solve. The append rule is identical.
- **Anywhere.** The four error categories and the empty-vs-unreachable distinction belong in your
  tool wrapper layer. No protocol hands them to you.
