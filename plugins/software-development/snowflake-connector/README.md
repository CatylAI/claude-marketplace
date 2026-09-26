# snowflake-connector

Bring-your-own-account Snowflake access for Claude Code. A setup skill takes you from "I have a
Snowflake login" to a verified, read-only connection, and a querying skill keeps every query
bounded, because in a data warehouse the risk is usually the bill, not an error message.

## What it is

Two skills and one MCP server entry. The plugin ships no account identifier, user, role or
credential. You supply them, either as plugin settings (MCP path) or as a local `snow` CLI
connection (fallback).

- **Default: Snowflake-managed MCP server.** `.mcp.json` registers a remote HTTP server named
  `snowflake`. Its URL and token come from two plugin settings, `snowflake_mcp_url` and
  `snowflake_pat` (a programmatic access token). Claude Code stores the token in the macOS
  Keychain, or `~/.claude/.credentials.json` elsewhere, never in `settings.json`.
  Until the URL is set, `/mcp` shows `snowflake` as `not configured` and Claude Code does not try
  to connect; with a URL but a missing or wrong token, it shows a failed connection (401). The
  skills fall back to the CLI path in both cases.
- **Fallback: the `snow` CLI** with key-pair authentication, for accounts without a managed MCP
  server.

Both paths use a dedicated read-only service user, so a misread instruction ends in a
permissions error instead of a changed table.

## When to use it

- Connecting to Snowflake for the first time, or after rotating a key or token.
- A connection fails and you need to find which layer broke: hostname, auth, role or grants.
- Writing, running or reviewing a warehouse query, especially one that might scan more than you
  intend.
- Working out why a query was slow or expensive.

## When not to use it

- **Applying grants.** The setup skill shows the `CREATE` and `GRANT` statements; someone with
  the rights runs them.
- **Writing to the warehouse.** The agent role is read-only. Before any non-`SELECT` statement,
  the querying skill stops and shows it to you.
- **Data modelling**, clustering strategy and ELT.

## Prerequisites

- A Snowflake account, and someone who can create a role, a service user and a warehouse.
- For the MCP path: a Snowflake-managed MCP server object in your account, and a PAT for the
  service user generated in Snowsight.
- For the CLI path: the Snowflake CLI (`snow`) and `openssl` on the machine running Claude Code.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install snowflake-connector@catylai
```

Claude Code asks for `snowflake_mcp_url` and `snowflake_pat` when you enable the plugin. You can
change `snowflake_mcp_url` later in `/config`. `snowflake_pat` is a sensitive field and does not
appear in `/config`; to replace it, disable and re-enable the plugin in `/plugin` to get the
prompt again (unverified). Start a new session so the server connects.

**Cowork and claude.ai:** enable the plugin for your claude.ai account. Whether Cowork prompts
for plugin settings is not documented; if it does not, add the same MCP server URL as a
claude.ai custom connector.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `snowflake-setup` | Skill | Account identifier, service user, read-only role and warehouse, then the MCP server or the `snow` CLI, verified one layer at a time | both |
| `snowflake-querying` | Skill | Bounded queries, `EXPLAIN` before expensive runs, result-cache and warehouse cost behaviour, query profiles, cancelling a runaway query | both |
| `snowflake` | MCP server (remote HTTP) | Snowflake-managed MCP server, configured through plugin settings | Claude Code |

Both skills load on either surface. Running anything against Snowflake needs either the MCP
server or a shell with the `snow` CLI. Without them, the skills hand you the SQL and steps to run
yourself, and work from the output you paste back.

Tool names from the server have the form `mcp__plugin_snowflake-connector_snowflake__<tool>`;
copy the exact names from `/mcp` before writing permission rules or hooks for them.

## Security notes

- Steps that prompt for a passphrase (openssl, an interactive `snow connection add`) are run by
  you in your own terminal, never through Claude's shell.
- Private keys live under `~/.snowflake/keys/`, created with `umask 077`. The key passphrase is
  supplied through `PRIVATE_KEY_PASSPHRASE` from your keychain, not stored in the connection file.
- The PAT is generated in Snowsight and entered only in the plugin's enable-time prompt. It never
  goes through the chat.
- `PRIVATE_KEY_PASSPHRASE` is in the environment of every command Claude runs, so any of them
  could read it.
- With `dev-guardrails` installed, its Bash hook blocks the common ways of printing a secret into
  the transcript: `cat`, `grep` and similar on `connections.toml`, `~/.snowflake/config.toml` or a
  `*.p8` key; `openssl` writing a private key to stdout; and `echo` or `printenv` of the
  passphrase variable. It is best-effort: an interpreter such as `python3 -c` can still read
  these files.

## Layout

```
snowflake-connector/
├── .claude-plugin/plugin.json          # manifest, including the userConfig settings
├── .mcp.json                           # the `snowflake` remote MCP server
├── skills/
│   ├── snowflake-setup/
│   │   ├── SKILL.md                    # identity, role, warehouse, MCP or CLI, verification
│   │   └── references/troubleshooting.md
│   └── snowflake-querying/SKILL.md     # bounded queries, cost controls, profiles
└── README.md
```

## Dependencies

- `dev-standards`: `secrets-management` sets the general rules for keeping secret values out of
  source, logs and chat, and for rotating a secret once it has been exposed. The Snowflake-specific
  storage steps are in `snowflake-setup`.

## License

MIT
