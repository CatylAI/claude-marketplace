---
name: snowflake-setup
license: MIT
description: "Setup wizard for connecting a Claude Code session to your own Snowflake account: finding your account identifier, choosing between key-pair, OAuth and SSO authentication, deciding which role the agent uses and why read-only is the right default, and verifying each layer of the connection separately. Use on first connection, after a credential rotation, or when a Snowflake connection fails and you need to find out which layer broke."
---

# Snowflake Setup

Work through this in order. Each step has a verification, and the verifications are
deliberately separate: *authentication working* and *the role being able to read anything*
are different problems with the same symptom if you check them together.

Every value in angle brackets is yours. This skill ships no account identifier, no client
id, no role name and no secret.

## Step 1 — find your account identifier

Snowflake has two identifier formats and an account URL that contains one of them. Most
connection errors at this step are a correct credential pointed at a hostname that does
not exist.

| Form | Looks like | Notes |
| --- | --- | --- |
| **Organization + account name** (preferred) | `<orgname>-<account_name>` | The current form. Stable across region moves. |
| **Account locator** (legacy) | `<locator>.<region>.<cloud>` | Still accepted in many places; some tools require one form or the other. |

Three ways to get it, in order of reliability:

1. **From Snowsight.** Open the account selector in the bottom-left, hover your account,
   and use the option to copy the account identifier or the account URL. This is
   authoritative — it is what your account actually is, not what someone remembered.
2. **From the URL you already log into.** An account URL has the shape
   `https://<account-identifier>.snowflakecomputing.com`. The part before
   `.snowflakecomputing.com` is what most connectors want.
3. **From a session you already have**, in a worksheet or `snow sql`:

   ```sql
   SELECT CURRENT_ACCOUNT()  AS account_locator,
          CURRENT_REGION()   AS region,
          CURRENT_ROLE()     AS role,
          CURRENT_WAREHOUSE() AS warehouse;
   ```

Write the identifier down once, in the connection config — not in a repository, not in a
skill, not in a chat message that gets pasted somewhere else later.

## Step 2 — choose an authentication method

| Method | Good for | Trade-offs |
| --- | --- | --- |
| **Key-pair** | Automation, CI, an agent that must run unattended | No browser, no session expiry to babysit, rotatable by adding a second key before removing the first. You are now responsible for a private key file: it must be passphrase-encrypted and it must never be committed. Best default for an agent. |
| **OAuth** (an integration in your account, or an external provider) | Human-in-the-loop use where the agent should act as *you*, with your grants and your audit trail | Short-lived tokens, no long-lived secret on disk, and the token carries a role. Costs a one-time admin setup — a security integration, a client id and secret, a redirect URI — and a re-authentication whenever the refresh token lapses. |
| **SSO / external browser** | Interactive sessions on a laptop where your organisation already federates identity | Simplest to start, inherits your organisation's MFA. Requires a browser at connect time, so it is unsuitable for anything unattended, and the session expires mid-task. |
| **Password** | Nothing, in practice | A long-lived reusable secret. Some accounts disable it outright, and where it works it should still be treated as the fallback of last resort. |

Choosing, in one line each:

- An agent that runs on its own → **key-pair**.
- An agent acting on your behalf, interactively, where per-user audit matters → **OAuth**.
- You, at a terminal, occasionally → **SSO**.

Auth method availability and configuration change; confirm the current options and required
parameters against your account's documentation before building anything around one.

### If you chose key-pair

Generate an encrypted private key and its public half. Use a passphrase — an unencrypted
private key on a laptop is a password file with extra steps:

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out snowflake_key.p8
openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key.pub
chmod 600 snowflake_key.p8
```

Register the public key on your user. The value is the base64 body **without** the
`-----BEGIN PUBLIC KEY-----` / `-----END PUBLIC KEY-----` lines and without newlines:

```sql
ALTER USER <your_user> SET RSA_PUBLIC_KEY='<public key body>';

-- Confirm it landed; the fingerprint is what the server will match against
DESC USER <your_user>;
```

To rotate without downtime, set `RSA_PUBLIC_KEY_2` to the new key, switch the client over,
verify, then clear the old one. Store the private key and its passphrase in your platform
keychain or secrets manager — see `dev-standards` → `secrets-management`.

### If you chose OAuth

Your account admin creates a security integration and gives you a **client id**, a **client
secret** and the **redirect URI** the integration will accept. The client secret is a
credential: keychain or secrets manager, never a repository.

Two details that account for most OAuth failures:

- **The scope carries the role.** Tokens minted under a different role than you expect will
  authenticate successfully and then fail every query with a permissions error. If the
  connector lets you request a role in the scope, request the one you intend to use.
- **The redirect URI must match exactly**, port included. If you change the local callback
  port on your side, the integration has to be updated too.

## Step 3 — decide which role the agent uses

**Default to a purpose-built read-only role.** Not `ACCOUNTADMIN`, not `SYSADMIN`, and not
your own role if your own role can write.

The reasoning is the same as for any other automated identity, with one Snowflake-specific
sharpening: an agent composes SQL from natural language, and natural language does not
reliably distinguish "show me" from "change". A role that cannot write turns a whole class
of misunderstanding into an error message instead of an incident. It also bounds cost —
a role with usage on one small warehouse cannot spin up the big one.

A minimal shape, run by someone who holds the rights to run it:

```sql
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS <AGENT_ROLE>;

USE ROLE SECURITYADMIN;
GRANT USAGE ON WAREHOUSE <WAREHOUSE> TO ROLE <AGENT_ROLE>;
GRANT USAGE ON DATABASE  <DATABASE>  TO ROLE <AGENT_ROLE>;
GRANT USAGE ON SCHEMA    <DATABASE>.<SCHEMA> TO ROLE <AGENT_ROLE>;
GRANT SELECT ON ALL TABLES    IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <AGENT_ROLE>;
GRANT SELECT ON ALL VIEWS     IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <AGENT_ROLE>;
GRANT SELECT ON FUTURE TABLES IN SCHEMA <DATABASE>.<SCHEMA> TO ROLE <AGENT_ROLE>;

GRANT ROLE <AGENT_ROLE> TO USER <your_user>;
ALTER USER <your_user> SET DEFAULT_ROLE = <AGENT_ROLE>;
ALTER USER <your_user> SET DEFAULT_WAREHOUSE = <WAREHOUSE>;
```

Notes that matter:

- **`FUTURE` grants are the difference between a role that keeps working and one that
  silently stops** as new tables appear. Without them, tomorrow's table is invisible and
  the failure reads as "no such table".
- **Set a default role.** A session that falls back to `PUBLIC` authenticates fine and then
  cannot see anything, which is the single most common "it connected but nothing works"
  report.
- **Set a default warehouse too.** With none, every query fails with no warehouse selected
  rather than with anything descriptive.
- `USAGE` on a warehouse lets the role *run* queries on it; it does not let the role resize
  it. That is the boundary you want.

### The warehouse the agent uses

Give the agent its own small warehouse rather than sharing the analytics one. It makes
cost attributable, and it caps the damage:

```sql
CREATE WAREHOUSE IF NOT EXISTS <WAREHOUSE>
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60      -- seconds of idle before it stops billing
  AUTO_RESUME    = TRUE
  INITIALLY_SUSPENDED = TRUE;

ALTER WAREHOUSE <WAREHOUSE> SET STATEMENT_TIMEOUT_IN_SECONDS = 300;
```

A statement timeout is a cost control, not a patience setting: it is the ceiling on what a
single runaway query can spend. Add a resource monitor on top if your account admin will —
that is the ceiling on what the whole warehouse can spend in a month.

## Step 4 — configure the client

For the Snowflake CLI, add a named connection and let the tool own the config file rather
than hand-editing it:

```bash
snow connection add
snow connection list
```

It writes `~/.snowflake/config.toml`. Treat that file as sensitive: `chmod 600`, never in a
repository, and if it holds a password or a private key path, the same rules apply as to
any other credential file.

If you are wiring an **MCP server** instead, the configuration will need, at minimum: your
account identifier, the auth method and its parameters, and the role and warehouse to use.
Every one of those is account-specific. Get the exact field names and the endpoint shape
from the server's own current documentation and fill them in yourself — a connector
configuration copied from an example is a connector pointed at somebody else's account.

This plugin deliberately ships **no** `.mcp.json`. A committed server configuration would
either carry real account values, which must never be published, or carry placeholders
that register a server guaranteed to fail on startup. Neither is better than writing four
lines of configuration once, knowingly.

## Step 5 — verify, one layer at a time

Run these in order and stop at the first failure. Each one isolates a different layer, and
running them together is how a role problem gets mistaken for an auth problem.

```bash
# 1. Auth only: can the client establish a session at all?
snow connection test --connection <name>
```

```sql
-- 2. Identity: is the session who and what you expect?
SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE(), CURRENT_DATABASE();
```

```sql
-- 3. Metadata read: does the role see the objects? Costs no warehouse compute.
SHOW TABLES IN SCHEMA <DATABASE>.<SCHEMA>;
```

```sql
-- 4. A real, bounded read: does the warehouse actually run a query for this role?
SELECT * FROM <DATABASE>.<SCHEMA>.<TABLE> LIMIT 10;
```

If step 2 shows a role you did not expect, fix the default role before going further;
everything after it will fail in a way that points at the wrong thing.

## Troubleshooting

| Symptom | Almost always |
| --- | --- |
| Cannot resolve the host, or a connection timeout | Wrong account identifier — the two identifier forms got mixed, or a region suffix was added to the organization form. Re-copy it from Snowsight. |
| Authentication succeeds, every query fails on permissions | The session's role. Check `CURRENT_ROLE()`; the token or the default role is `PUBLIC` or something else with no grants. |
| "No warehouse selected" or similar | No default warehouse on the user, and the connection does not specify one. |
| A table exists and the role cannot see it | Missing `FUTURE` grants — it was created after the one-time `ALL TABLES` grant. |
| Key-pair auth rejected | Public key body registered with the PEM header/footer or embedded newlines; or the private key's passphrase is not being supplied. Compare the fingerprint from `DESC USER`. |
| OAuth authorize page 404s | The provider's discovery endpoint is not where the client assumed. Confirm the exact URL with whoever created the integration rather than guessing a path. |
| It worked yesterday | A token or SSO session expired, or a key was rotated. Re-authenticate before debugging anything else. |

Once connected, go to `snowflake-querying` before running anything larger than the
verification query above.
