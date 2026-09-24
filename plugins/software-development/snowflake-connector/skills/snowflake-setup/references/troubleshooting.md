# Snowflake connection troubleshooting

Find the symptom, apply the usual cause, then rerun the Step 5 check that failed.

| Symptom | Usual cause |
| --- | --- |
| Cannot resolve the host, or the connection times out | Wrong account identifier: the two forms got mixed, or a region suffix was added to the organization form. Copy it again from Snowsight. |
| `/mcp` shows `snowflake` as `not configured` | `snowflake_mcp_url` is empty. Set it in `/config`, then start a new session. |
| `/mcp` shows `snowflake` as a failed connection | `snowflake_pat` is empty or wrong, or the URL is wrong. The PAT does not appear in `/config`; disable and re-enable the plugin in `/plugin` to enter it again (unverified). |
| MCP returns 401 or 403 | The PAT has expired or been revoked, it is restricted to a different role, or the user has no network policy that admits it. |
| Authentication succeeds, every query fails on permissions | The session's role. Check `CURRENT_ROLE()`; the default role or the PAT's role restriction is not `<AGENT_ROLE>`. |
| The agent can write, or `CURRENT_SECONDARY_ROLES()` is not empty | Secondary roles are on. Set `DEFAULT_SECONDARY_ROLES = ()` on the user and `--secondary-roles NONE` on the CLI connection. |
| "No warehouse selected" or similar | No default warehouse on the user, and the connection does not name one. |
| A table exists and the role cannot see it | Missing `FUTURE` grants: the object was created after the one-time `ALL` grant. |
| Key-pair auth rejected | The public key was registered with the PEM header/footer or embedded newlines, or `PRIVATE_KEY_PASSPHRASE` is not set in the environment Claude Code started from. Compare fingerprints (Step 5.6). |
| `snow` refuses to read its config file | The file is readable by other users. Restore mode 0600. |
| `snow connection add` hangs or aborts | It was run without `--no-interactive` from the Bash tool. Use the non-interactive form, or have the user run it in their own terminal. |
| It worked yesterday | A token expired or a key was rotated. Re-authenticate before debugging anything else. |
