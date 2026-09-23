# snowflake-connector

Bring-your-own-account Snowflake access for Claude Code: a setup wizard that walks you from
"I have a Snowflake login" to a verified, read-only connection, and a querying skill built
around the fact that the hazard in a data warehouse is the bill rather than the error
message.

Works in **Claude Code** and in **Cowork** (Claude Code on the web) — with an important
caveat about shell access and credentials, below.

## What it is

Two skills and nothing else. There is no account identifier, no client id, no role name and
no credential anywhere in this plugin, and there never will be. Every account-specific
value is a placeholder you fill in: `<orgname>-<account_name>`, `<WAREHOUSE>`, `<ROLE>`,
`<DATABASE>.<SCHEMA>`.

That is a deliberate design choice rather than a precaution. A connector shipping one
team's account details works perfectly for that team and fails for everyone else in a way
that looks like a bug instead of like missing configuration.

## When to use it

- Connecting a session to Snowflake for the first time, or after rotating a key or a
  client secret.
- Deciding between key-pair, OAuth and SSO authentication for an agent, and which role it
  should run as.
- A connection fails and you need to find out which layer broke — hostname, auth, role, or
  grants.
- Writing or reviewing a warehouse query, especially one that might scan more than you
  intend.
- Working out why a query was slow or expensive, from its profile rather than from a guess.

## When not to use it

- **You want grants applied.** These skills tell you which grants to ask for and why. They
  do not run `GRANT`; if you hold the rights, running it is a deliberate act you perform
  yourself.
- **You want somewhere to keep the credential.** Private keys, client secrets and
  passwords belong in your platform keychain or secrets manager — `dev-standards` →
  `secrets-management` has the conventions.
- **You are designing tables.** Data modelling, clustering strategy and ELT are out of
  scope.
- **You want to write to the warehouse.** The default posture here is read-only; where a
  statement would write, the skill says so and stops.

## Prerequisites

A Snowflake account you can already log into, and a client — the Snowflake CLI, a driver,
or an MCP server — on the machine running Claude Code. The setup skill covers finding your
account identifier, choosing an auth method and creating a read-only role; it assumes
someone with the appropriate rights runs the statements that need them.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install snowflake-connector@catylai
```

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `snowflake-setup` | Skill | Find your account identifier, choose between key-pair / OAuth / SSO, create and grant a read-only role and its own small warehouse, then verify auth, identity, metadata and a real read as four separate steps | both |
| `snowflake-querying` | Skill | Bound every query by time and row count, size and suspend the warehouse as a spend control, avoid the expensive query shapes, and read a query profile for pruning, spilling and exploding joins | both |

Everything listed as a Skill loads on both surfaces. You can call one by name in Claude
Code, or just describe what you want on either surface and let it trigger itself.

**These skills are fully readable on both surfaces, but only executable on one.** Every
step they describe — `snow connection test`, a `GRANT`, a verification `SELECT`, reading a
query profile — needs a shell, a client and live Snowflake credentials, and Cowork has
none of those. The wizard, the trade-off tables and the query checklists are text and work
anywhere; actually connecting to an account means Claude Code.

### No `.mcp.json`, on purpose

This plugin ships no MCP server configuration. A committed one would either carry a real
account identifier, client id and role — which must never be published — or carry
placeholders that register a server guaranteed to fail at startup and look like a broken
plugin. The setup skill tells you what a client configuration needs instead, and points you
at your server's own documentation for the exact field names and endpoint shape. Four lines
of configuration written knowingly beats a file that is wrong by construction.

## Layout

```
snowflake-connector/
├── .claude-plugin/plugin.json              # manifest (name, version, description, dependencies)
├── SKILL.md                                # plugin entry point; scope and the bring-your-own-account rule
├── skills/
│   ├── snowflake-setup/SKILL.md            # account identifier, auth method, role, warehouse, verification
│   └── snowflake-querying/SKILL.md         # bounded queries, warehouse cost controls, query profiles
└── README.md
```

## Dependencies

- `dev-standards` — in particular `secrets-management`, which owns where a private key,
  client secret or connection file is allowed to live and what happens when one is
  exposed.

## License

MIT
