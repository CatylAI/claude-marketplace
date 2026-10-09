# Porting MCP integration to other clients

Read this when the server will also be used by clients other than Claude Code.

- **Other MCP clients.** The server itself carries over unchanged. What varies is which MCP
  features each client supports. Resources, prompts and elicitation are not universal, so a server
  that requires resources will degrade on a client that only supports tools. Design the tools to
  work on their own, and treat resources as the fast path.
- **Tool layers that aren't MCP.** The `mcp__server__tool` naming is a Claude-side convention, and
  `isError` is the MCP result field. Normalize both at the bridge, and keep your own error-category
  convention on your side of it.
- **Anywhere.** Two principles are not protocol features and apply to any tool layer: expose
  catalogs as data rather than as discovery calls, and remember that descriptions decide routing.
