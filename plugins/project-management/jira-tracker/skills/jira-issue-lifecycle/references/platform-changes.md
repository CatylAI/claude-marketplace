# Jira and Atlassian MCP: dated facts

Verify against current docs. Everything in this file has a date attached or can change without
notice, which is why the skill bodies point here instead of repeating it. When a fact below no
longer matches what the site or server returns, trust the live response and update this file.

## REST API v3

- **`/rest/api/3/search` is removed.** It returns HTTP 410 and names changelog entry
  CHANGE-2046; the shutdown rolled out between August and October 2025. Use
  `/rest/api/3/search/jql` (GET or POST). It pages with `nextPageToken`, has no `startAt` and
  no `total`, and returns only issue ids unless you name `fields`. For a count, use
  `POST /rest/api/3/search/approximate-count`, and quote the result as approximate.
  Source: https://developer.atlassian.com/changelog/#CHANGE-2046
- **Epic Link and Parent Link are removed from the REST APIs and webhooks.** Parent Link went on
  13 June 2025 and Epic Link on 13 September 2025. `parent` is the one hierarchy field for
  company-managed and team-managed projects, at every level (sub-task to standard issue,
  standard issue to epic, epic to the levels above it). Older saved filters and automation that
  still name `Epic Link` need updating by whoever owns them.
  Source: https://community.developer.atlassian.com/t/deprecation-of-the-epic-link-parent-link-and-other-related-fields-in-rest-apis-and-webhooks/54048

## Atlassian Rovo MCP server

Source for this section: https://github.com/atlassian/atlassian-mcp-server (README, `.mcp.json`,
`server.json` and `skills/README.md`), read on 2026-09-25.

- **Endpoint.** `https://mcp.atlassian.com/v2/mcp` is the recommended endpoint (streamable
  HTTP). The v1 endpoints `https://mcp.atlassian.com/v1/mcp` and `/v1/mcp/authv2` remain
  supported, and existing v1 connections expose the v2 tools. The SSE endpoint
  `https://mcp.atlassian.com/v1/sse` is unsupported after 30 June 2026.
- **Auth.** OAuth 2.1 through the browser, or an API token: a personal token as
  `Authorization: Basic <base64(email:api_token)>`, or a service-account key as
  `Authorization: Bearer <api_key>`. API-token auth works only after an organization admin
  enables it (Atlassian Administration → Rovo → Rovo MCP server → Authentication).
- **Permission groups for Jira.** `read_jira`, `write_jira` and `search_jira` are on by default;
  `delete_jira` and `manage_jira` are off until an admin enables them.
- **Primary tools and the catalog.** v2 lists a few primary tools directly and reaches the rest
  through a `discover` meta-tool plus an execute tool (`execute`, or `executeRead` /
  `executeWrite` / `executeDestructive`). Appending `?tools=all` to the URL exposes every tool
  as a flat list instead.
- **Renamed Jira tools (v1 → v2).** `getVisibleJiraProjects` → `listJiraProjects`,
  `getJiraProjectIssueTypesMetadata` → `listJiraProjectIssueTypesMetadata`,
  `addCommentToJiraIssue` → `addOrEditJiraIssueComment`. `createJiraIssue` takes `issueType`
  and `assignee` rather than `issueTypeName` and `assignee_account_id`.
- **Tools named only in Atlassian's supported-tools list**, seen through search results because
  support.atlassian.com and developer.atlassian.com were not reachable when this was written:
  `getTransitionsForJiraIssue`, `transitionJiraIssue`, `editJiraIssue`, `lookupJiraAccountId`,
  `getIssueLinkTypes`, `getJiraIssueRemoteIssueLinks`, `addWorklogToJiraIssue`. Confirm each
  against the live tool list or `discover` before relying on its parameters.
  Reference: https://support.atlassian.com/atlassian-rovo-mcp-server/docs/supported-tools/

## Smart Commits

Smart Commits are a long-standing Jira feature: a commit message such as
`PROJ-123 #comment Fixed the retry bound` or `PROJ-123 #time 1h`, or `PROJ-123 #<transition-name>`
(spaces in the transition name written as hyphens), acts on the issue when the commit reaches a
connected repository. They need a source integration (Bitbucket, GitHub for Jira, GitLab or a
DVCS account) with Smart Commits enabled by an admin, and the commit author's email must match
exactly one Jira user. This summary comes from search results; the Atlassian page could not be
fetched, so check the exact syntax with the team's admin before relying on it.
Reference: https://support.atlassian.com/jira-software-cloud/docs/process-issues-with-smart-commits/
