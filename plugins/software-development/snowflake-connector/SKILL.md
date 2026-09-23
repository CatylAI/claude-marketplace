---
name: snowflake-connector
description: "Connect a Snowflake account to a Claude Code session and query it safely. Use when setting up Snowflake access — discovering your account identifier, choosing between key-pair, OAuth and SSO authentication, picking a role — or when writing a warehouse query where the hazard is cost rather than correctness. Ships no account, no credential and no role: every value is yours to supply."
license: MIT
user-invocable: false
---

# Snowflake Connector

Two skills. One gets you connected to **your own** account; the other keeps a query from
costing more than the answer is worth.

## Bring your own account

This plugin contains no account identifier, no client id, no role name and no credential,
and it never will. Every account-specific value is a placeholder you fill in:
`<orgname>-<account_name>`, `<WAREHOUSE>`, `<ROLE>`, `<DATABASE>.<SCHEMA>`.

That is not only hygiene. A connector that ships someone else's account details is a
connector that silently works for exactly one team and fails confusingly for everyone
else — and the failure looks like a bug rather than like missing configuration.

## What is in here

| Component | Type | Use when |
|-----------|------|----------|
| `snowflake-setup` | Skill | Connecting for the first time, or after a credential rotation: finding your account identifier, choosing an auth method, deciding which role the agent uses, and verifying the connection actually works. |
| `snowflake-querying` | Skill | Writing or reviewing a query against a warehouse. Bounding by time and row count, sizing and suspending the warehouse, avoiding the expensive shapes, and reading a query profile when something is slow. |

## The hazard is the bill

Most data tools fail loudly: a bad query errors, and you fix it. Snowflake separates
storage from compute and charges for compute by the second while a warehouse is running,
so a careless query does not fail — it **succeeds, slowly, on a large warehouse**, and the
cost shows up on an invoice weeks later with nobody's name on it.

`SELECT * FROM <big_table>` on a 4X-Large is a valid query. It returns rows. Nothing in
the result tells you what it cost. Treat an unbounded query the way you would treat an
unbounded log read in production: not as a style issue, but as the thing most likely to go
wrong.

The rule the querying skill is built around: **a query whose expected row count you cannot
state has not been thought through.** Say the number before you run it, then check.

## Not this plugin's job

- **Granting anything.** These skills tell you which grants to ask for and why a read-only
  role is the right default. They do not run `GRANT`, and if you are the account admin,
  running them is a deliberate act you should perform yourself.
- **Storing your credential.** Key-pair private keys, OAuth client secrets and passwords go
  in your platform keychain or secrets manager. See `dev-standards` →
  `secrets-management`; nothing sensitive belongs in a repository or in a skill file.
- **Writing to your warehouse.** The default posture here is read-only. Where a statement
  would write, the skill says so and stops.
- **Deciding your data model.** Table design, clustering strategy and ELT are out of
  scope. This is about connecting and querying without hurting yourself.
