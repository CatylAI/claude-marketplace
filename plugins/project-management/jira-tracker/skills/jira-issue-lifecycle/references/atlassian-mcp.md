# Atlassian Rovo MCP server: the primary path

Atlassian's own remote MCP server acts as the signed-in user, inside that user's Jira
permissions, and needs no token in the shell. It works in Claude Code and, as a claude.ai
connector, in web and Cowork sessions. Endpoint, auth and rename details that carry a date are
in `platform-changes.md`.

## Contents

- Connecting
- Checking it works
- Operation map
- Calling rules
- When a call fails

## Connecting

Use one of these, not both; a server added in Claude Code hides a claude.ai connector that
points at the same URL.

- **claude.ai connector** (web, Cowork, and Claude Code when logged in with a claude.ai
  account): add Atlassian at https://claude.ai/customize/connectors and sign in there. On Team
  and Enterprise plans an admin adds it. Connectors are read when a session starts, so start a
  new session afterwards.
- **Claude Code only:** `claude mcp add --transport http atlassian https://mcp.atlassian.com/v2/mcp`,
  then run `/mcp` in a session to sign in through the browser.

The Jira site admin controls which permission groups the server may use and which client
domains and IP ranges may connect. A call refused for policy reasons needs the admin, not a retry.

## Checking it works

1. Look for Jira tools in the tool list (names such as `getJiraIssue` and
   `searchJiraIssuesUsingJql`, possibly prefixed with the server's name), or for the
   `discover` and execute meta-tools.
2. Call `getAccessibleAtlassianResources`. It returns each site the user can reach with its
   `id`, which is the `cloudId` every Jira tool takes. Confirm the site URL is the one the
   project uses; with several sites, ask which one.
3. Fetch one known issue with `getJiraIssue`. A result means read access works.

## Operation map

Names verified in Atlassian's published v2 skills are marked **v2**. The rest come from
Atlassian's supported-tools list (see `platform-changes.md`); confirm them in the tool list or
with `discover` before the first use.

| Operation | Tool | Notes |
| --- | --- | --- |
| Find the `cloudId` | `getAccessibleAtlassianResources` **v2** | Once per session. |
| Read an issue | `getJiraIssue(cloudId, issueIdOrKey)` **v2** | Check the result carries the status category, resolution, assignee and parent you need. |
| JQL search | `searchJiraIssuesUsingJql(cloudId, jql, fields, maxResults)` **v2** | Name the fields you need. Page with the `nextPageToken` the result returns. |
| Projects | `listJiraProjects` **v2**, not primary | Through the execute tool. |
| Issue types for a project | `listJiraProjectIssueTypesMetadata` **v2**, not primary | Inputs `projectIdOrKey`. Look for each type's hierarchy level. |
| Fields for one issue type | `getJiraIssueTypeMetaWithFields` **v2**, not primary | Inputs `projectIdOrKey`, `issueTypeId`. The required fields a create must carry. |
| Create | `createJiraIssue(cloudId, projectKey, issueType, summary, description, …)` **v2** | Takes `parent` (a key) and `assignee`; other fields go in `additional_fields`. |
| Comment | `addOrEditJiraIssueComment(cloudId, issueIdOrKey, commentBody)` **v2** | Markdown body. |
| Find a user's `accountId` | `lookupJiraAccountId` | |
| Edit fields (assignee, parent, labels, resolution) | `editJiraIssue` | |
| List transitions from the current status | `getTransitionsForJiraIssue` | Run it every time; ids differ per workflow. |
| Run a transition | `transitionJiraIssue` | By transition id; screen fields travel with it. |
| Issue link types | `getIssueLinkTypes` | For links; a link is not a parent. |

For a non-primary operation, call the execute tool with the operation name, the `cloudId` as a
top-level argument, and a flat `inputs` object:

```
executeRead(name="listJiraProjectIssueTypesMetadata", cloudId="<cloudId>", inputs={"projectIdOrKey": "PROJ"})
```

Use `executeWrite` for writes when the client exposes the split tools, or `execute` when it
exposes one. For any operation not shown with its inputs here, take the input names from the
`discover` result or the tool schema.

## Calling rules

- **Use the parameter names from the live schema.** Per Atlassian's own skills, the server drops
  an unrecognised parameter without an error, so a misspelled field "succeeds" and changes
  nothing. The read-back after each write is what catches it.
- **Bodies are Markdown.** Descriptions and comments go in as Markdown strings; the server builds
  the Atlassian Document Format. Check the rendered result on the read-back the first time.
- **Ask for what you need.** Search with a modest `maxResults` and only the fields you need,
  then page; every returned field costs context.

## When a call fails

| Symptom | Next step |
| --- | --- |
| No Jira tools and no `discover` in the tool list | The server is not connected in this session. Say so, point the user at "Connecting" above, and use the REST path (Claude Code) or a pasted issue. |
| Authentication or "needs sign-in" error | Ask the user to sign in again: `/mcp` in Claude Code, or reconnect at claude.ai/customize/connectors for a connector. Do not loop on the call. |
| Unknown tool or operation | Run `discover` with the goal in plain words and use the name it returns. |
| Permission denied on a write | The user or the server's permission group lacks it (for example `write_jira` disabled). Report it; print the change for the user to make in Jira. |
| The write returned success but the read-back shows no change | A parameter name was wrong and was dropped. Re-read the schema and repeat once. |
