---
name: jira-tracker
description: "The Jira adapter for issue-tracker-core — the concrete Jira Cloud REST API v3 calls that carry out the pre-work gate, the comment trail, the status vocabulary, epic and parent links and the orphan sweep against a Jira project. Use when the repository's tracker is Jira and you need the actual call rather than the rule: finding or creating a scoped assigned issue, reading an issue with its comments, transitioning it, writing a JQL sweep, or attaching a child to an epic."
license: MIT
user-invocable: false
---

# Jira Tracker

`issue-tracker-core` states the discipline and deliberately names no vendor: no
endpoint, no issue-type identifier, no transition identifier, no project key.
This plugin is the layer that supplies those for Jira Cloud, and nothing else.
Read the core for what a call is *for*; read this for the call.

## What this adapter supplies that the core withholds

| The core says | This adapter supplies |
| --- | --- |
| "Fetch the item from the tracker." | `GET /rest/api/3/issue/<KEY>` and the field names that come back. |
| "Move it to the in-progress state." | Jira has no fixed state set. `GET`/`POST /rest/api/3/issue/<KEY>/transitions`, and the rule that transition IDs are per-workflow. |
| "Set a parent before continuing." | The `parent` field, the Epic Link custom field, and which of the two your project actually uses. |
| "Run the candidate-parent query." | JQL — the two-stage shortlist and full-set queries, run live. |
| "Comment at start, handoff and finish." | `POST /rest/api/3/issue/<KEY>/comment`, and the ADF body shape v3 requires. |
| "Terminal states distinguish finished from abandoned." | `statusCategory` plus the project's own terminal statuses, which are configured rather than fixed. |
| "Filter on the state category, not a single state name." | `statusCategory != Done` in JQL, and why `status != Done` is the wrong spelling. |

## Precondition: an authenticated Jira Cloud credential

Every procedure here is an HTTP call to your Jira site. Before running any of
them, confirm the credential resolves and identifies the account you expect:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/myself"
```

That returns your own `accountId`, `displayName` and `emailAddress`. If it
returns `401` or an anonymous body, stop and say so — do not fall back to
guessing issue state from the working tree, and do not proceed with a key you
have not resolved.

`JIRA_EMAIL` and `JIRA_API_TOKEN` are environment variables or `op://`
references. **A token never appears literally in a skill, a script, a commit or
a comment.** Jira Cloud API tokens are created per-account in Atlassian account
settings and are used as the password half of HTTP Basic auth alongside the
account's email address.

Throughout, `<SITE>`, `<PROJECT_KEY>`, `<KEY>`, `<EPIC_KEY>`, `<BOARD_ID>`,
`<ACCOUNT_ID>` and `<TRANSITION_ID>` are placeholders. Substitute your own;
never paste an identifier out of an example.

## Why REST v3 over `curl`, and not `acli`

Atlassian ships a CLI (`acli`) and it is a reasonable thing to prefer where you
already use it. This plugin is written against the REST API instead, for three
reasons:

1. **The API surface is what the CLI wraps.** Every procedure here maps onto a
   documented endpoint, and when a call fails you can see the request and the
   response body rather than a wrapper's error string.
2. **The CLI's subcommand surface has moved.** `acli` was reworked, and command
   names and flags differ between the older and current generations. This
   document would be shipping guesses.
3. **Nothing here needs a shell-native tool.** The calls are plain HTTP with a
   JSON body.

**If you are confident of your `acli` version's commands, use them** — the
discipline in this plugin is about what to send and when, not about which client
sends it. Do not translate an endpoint into an `acli` invocation by guessing the
subcommand name; check `acli --help` first.

## The ticket-pattern seam: Jira is the case where the default already works

`issue-tracker-core` shares `CLAUDE_TICKET_PATTERN` (default
`[A-Z][A-Z0-9]+-[0-9]+`) with the sibling `dev-guardrails` plugin so branch
parsing and commit-scope suggestion agree about what an issue key looks like.

**Jira issue keys match that default natively, unchanged.** A Jira key is a
project key — uppercase letters and digits, beginning with a letter — a hyphen,
and an incrementing number. That is precisely the shape the default regex
describes. This is the one tracker in this catalog where the seam is not a seam:
install the plugin, set nothing, and the gate finds the key on a branch named
`feature/PROJ-123-add-auth-middleware`.

Contrast the sibling `github-issues` adapter, which had to solve this. GitHub
issues are bare numbers written `#123` with no alphabetic prefix, so the default
pattern matches nothing in a GitHub repository and the gate silently finds no
key on a correctly named branch. That adapter's plugin-root `SKILL.md` documents
two resolutions — a synthetic `GH-` prefix, or a bare `[0-9]+` pattern that
matches every number anywhere — and requires the repository to pick one and
write it down. None of that is necessary here.

Two honest caveats, because "it works by default" is not "it cannot be wrong":

- **The default matches any project's key shape, not yours specifically.** In a
  repository whose branches reference more than one Jira project, or that
  contains a branch like `docs/RFC-2119-alignment`, the pattern will match
  something that is not your issue. Tighten it per repository when that bites:
  `CLAUDE_TICKET_PATTERN=<PROJECT_KEY>-[0-9]+`.
- **Matching the pattern is not evidence the issue exists.** The core says this
  and it is worth restating here, because a Jira key is so plausible-looking that
  it invites being trusted. Fetch the issue.

## Every numeric identifier is configuration, not content

Issue-type IDs, transition IDs, status IDs, priority IDs, resolution IDs, field
IDs of the form `customfield_NNNNN`, the site's Cloud ID, board IDs, sprint IDs
and project keys **all differ per Jira instance**. A value that is correct on one
site is wrong on another, and — worse — is often *accepted* on another, because
the numbers collide across instances and Jira will happily create a Task where
you meant a Bug.

**So this plugin ships none of them.** It ships the endpoint that enumerates
each one on your own site:

| Identifier | Discover it with |
| --- | --- |
| Your own `accountId` | `GET /rest/api/3/myself` |
| Project key, id, and style | `GET /rest/api/3/project/search?query=<TEXT>` |
| Issue-type IDs for a project | `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes` |
| Required fields for one issue type | `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes/<ISSUE_TYPE_ID>` |
| Field IDs, including `customfield_NNNNN` | `GET /rest/api/3/field` |
| Transition IDs available from an issue's current status | `GET /rest/api/3/issue/<KEY>/transitions` |
| Statuses and their categories | `GET /rest/api/3/status`, `GET /rest/api/3/statuscategory` |
| Priority IDs | `GET /rest/api/3/priority` |
| Resolution IDs | `GET /rest/api/3/resolution` |
| Board and sprint IDs | `GET /rest/agile/1.0/board?projectKeyOrId=<PROJECT_KEY>` |
| Cloud ID (only needed by APIs addressed through `api.atlassian.com`) | See the note below |

That discovery-over-hardcoding rule is the core's stated reason for existing.
`parent-child-hygiene` makes the same argument about the candidate-parent list:
**a cached table is wrong within weeks and is trusted while wrong**, and a
staleness note only makes the staleness documented. Numeric identifiers are the
same defect with a different spelling — they drift when an admin edits a
workflow, and nothing tells you.

**On the Cloud ID.** You do not need one to call
`https://<SITE>.atlassian.net/rest/api/3/...` with an API token; the site host
already identifies the tenant. A Cloud ID is required only when you address the
tenant through the gateway at `https://api.atlassian.com/ex/jira/<CLOUD_ID>/...`,
which is the OAuth path. **Flagged as uncertain:** the OAuth route to it is
`GET https://api.atlassian.com/oauth/token/accessible-resources` with a bearer
token, which returns an `id` per accessible site; there is also a
`/_edge/tenant_info` path on the site host that is widely used and not, as far as
this document can establish, formally documented. Verify whichever you use
before building on it, and never hardcode the result.

## Skills

| Skill | Use it when |
| --- | --- |
| `jira-issue-lifecycle` | Satisfying the pre-work gate, reading an issue's full state with its comments, posting the start/handoff/finish comments, transitioning, closing. |
| `jira-jql` | Writing any query — the triage sweeps, the orphan sweep, the candidate-parent shortlist. JQL is the query language for every read in this plugin. |
| `epic-and-parent-hygiene` | Attaching a child to an epic or a parent, auditing a backlog for orphans, or working out which hierarchy mechanism your project actually uses. |

## Not this plugin's job

- **Merge request and pull request lifecycle.** Opening, reviewing, merging and
  the checks that gate a merge belong to the forge adapter for whatever hosts
  your code. This plugin stops at the issue and at the reference that links a
  change back to it.
- **Judgement about the work.** Whether an item is well scoped, whether a state
  is honest, whether an orphan should be re-parented or declined — that is
  `issue-tracker-core`, and it is deliberately not restated here. When the two
  appear to conflict, the core wins and this adapter has a bug.
- **Commit message format.** `dev-standards` owns Conventional Commits; the core
  adds only that the scope is the issue key.
- **Jira administration.** Creating projects, editing workflows, adding statuses,
  defining custom fields and managing permission schemes are admin operations.
  This plugin reads that configuration and never changes it.
- **Confluence, Bitbucket and the rest of the Atlassian suite.** One vendor is
  not one product. This adapter is Jira only.
