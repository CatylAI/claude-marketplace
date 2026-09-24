# Porting tool design to other stacks

> **Verify against current docs.** Other vendors' tool APIs change; confirm names and limits in their
> own documentation.

- **OpenAI function calling and Agents SDK.** Description depth, namespacing, consolidation, and
  high-signal responses transfer verbatim; they are model-ergonomics rules, not vendor features.
  `tool_choice` has analogous shapes, and strict function schemas are the analogue of strict tool
  use. Without a built-in tool search, build your own retrieval-over-tools layer at high tool counts;
  the 30–50 degradation band still applies.
- **LangChain tools.** The docstring *is* the description, so short docstrings are the default
  failure mode. Set an args schema with per-field descriptions rather than relying on inferred types,
  and return strings you designed rather than the repr of an ORM object.
- **MCP servers.** The same rules, plus annotations disclosing destructive or open-world behavior.
  MCP uses `isError` where the Claude API uses `is_error`; normalize at your boundary.
- **Anywhere.** "Errors are prompts" and "empty is not unreachable" are the two rules teams most
  often skip and most often regret.
