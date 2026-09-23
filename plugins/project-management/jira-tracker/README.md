# jira-tracker

The Jira adapter for `issue-tracker-core`. The core plugin states the discipline in
vendor-neutral terms — require a real, scoped, assigned issue before any code is
written; keep the issue key recoverable from the branch; use a status vocabulary whose
states are checkable claims; keep every item under a live parent; treat the issue as the
durable record. This plugin supplies the concrete Jira Cloud REST API v3 calls that carry
those procedures out against a Jira project.

Nothing here restates the core's reasoning. Read the core for what a call is for; read
this for the call.

## When to use it

- The repository's tracker is Jira, and you need the actual call rather than the rule.
- You are satisfying the pre-work gate: finding or creating a scoped, assigned issue
  before the first edit.
- You need to transition an issue and do not know which transition ids this project's
  workflow uses — the answer is always "discover them", and this plugin shows how.
- You are writing JQL: a triage sweep, a duplicate check, an orphan audit, or the
  shortlist of candidate epics for a new issue.
- You are attaching a child to an epic and need to know whether this project uses the
  `parent` field or a legacy Epic Link custom field.

## When not to use it

- **Merge request or pull request lifecycle.** Opening, reviewing, merging and the checks
  that gate a merge belong to the adapter for whatever forge hosts your code. This plugin
  stops at the issue and at the reference linking a change back to it.
- **Judgement about whether the work is well scoped or a state is honest.** That is
  `issue-tracker-core`, and it is deliberately not duplicated here.
- **Jira administration.** Creating projects, editing workflows, adding statuses and
  defining custom fields are admin operations. This plugin reads that configuration and
  never changes it.
- **A tracker that is not Jira.** Load the adapter for that tracker instead. The core is
  shared; the adapter is not.
- **Confluence, Bitbucket and the rest of the Atlassian suite.** One vendor is not one
  product.

## Prerequisites

A Jira Cloud site you can read, and an API token for an account on it. Verify both before
running anything, because an expired credential and a genuinely empty backlog return
results that look alike:

```
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/myself"
```

That returns the account's own `accountId`, `displayName` and `emailAddress`. A `401` or
an anonymous body means stop, not improvise.

`JIRA_EMAIL` and `JIRA_API_TOKEN` are environment variables or `op://` references. **No
token appears literally in a skill, a script, a commit or a comment.** A Jira Cloud API
token is created per-account in Atlassian account settings and is used as the password
half of HTTP Basic auth alongside the account's email address.

### Permissions for a read-only pass

Browse Projects on the project is enough to read issues, comments, statuses and to run
every sweep in the `jira-jql` skill. Writing needs more:

| Operation | Needs |
|-----------|-------|
| Read issues, comments, JQL sweeps | Browse Projects |
| Create an issue | Create Issues |
| Edit fields, set a parent | Edit Issues |
| Comment | Add Comments |
| Transition | Transition Issues |
| Assign | Assign Issues (and Assignable User for the person being assigned) |

An audit or a triage read should run with the first row only. The plugin is written so
that the read-only path is genuinely read-only.

### REST API v3 over `curl`, not `acli`

Atlassian ships a CLI. This plugin is written against the REST API instead: the API is
what the CLI wraps, its failures are legible as a request and a response body, and the
CLI's subcommand surface has been reworked, so documenting it here would mean shipping
guesses. If you are confident of your `acli` version's commands, use them — the
discipline is about what to send and when, not about which client sends it. Check
`acli --help` rather than translating an endpoint into a guessed subcommand.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install jira-tracker@catylai
```

Install `issue-tracker-core` alongside it — this plugin is an adapter and assumes the
core's rules are loaded.

**Cowork / web:** `/plugin` is not available in web sessions. Enable this plugin for your
claude.ai account and Claude Code loads it automatically as a synced plugin.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `jira-issue-lifecycle` | Skill | Satisfy the pre-work gate against Jira, read an issue with its full comment thread, discover and run transitions, post the start/handoff/finish comments as Atlassian Document Format, close with a resolution and reopen without leaving one behind | both |
| `jira-jql` | Skill | The search endpoint and its token pagination, the clause and operator reference, `statusCategory` versus `status`, the triage sweeps, the orphan sweep, and the rule that a candidate-parent list is a live query and never a cached table | both |
| `epic-and-parent-hygiene` | Skill | Which field this project links children with, the hierarchy levels, the two-stage candidate-epic query, setting and verifying a parent, and the audits for dead parents and stranded children | both |

Everything here is a Skill, so all three load on both surfaces. You can call one by name
in Claude Code, or just describe what you want on either surface and let it trigger
itself.

**Every procedure in this plugin drives `curl` against the Jira REST API.** The skills are
readable on both surfaces — the endpoints, the JQL, the payload shapes and the reporting
formats are all text — but they are only *executable* where a shell and a Jira credential
exist, which in practice means Claude Code. In Cowork there is no shell, so treat these
skills as reference there: they will tell you exactly which call to make, and you will
make it yourself.

## Layout

```
jira-tracker/
├── .claude-plugin/plugin.json               # manifest (name, version, description, dependencies)
├── README.md
├── SKILL.md                                 # plugin root: the adapter contract, the auth
│                                            #   precondition, and the discovery-over-hardcoding rule
└── skills/
    ├── jira-issue-lifecycle/SKILL.md
    ├── jira-jql/SKILL.md
    └── epic-and-parent-hygiene/SKILL.md
```

## The `issue-tracker-core` seam

`issue-tracker-core` names no vendor on purpose. It has no endpoints, no issue-type
identifiers, no transition ids, no project key — it says that an item must exist and be
assigned before work starts, that a state is a claim someone will act on without
verifying, that a candidate-parent list is a query and never a cached table, and that the
issue rather than the chat is the durable record. Those statements survive a tracker
migration, which is exactly why they are separated out. This plugin is the other half: it
supplies the endpoint names, the payload shapes and Jira's own vocabulary. Where the two
appear to conflict, the core wins and this adapter has a bug — the adapter's job is to
make the core's rules executable, never to relax them because Jira makes one awkward.

The mapping is stated honestly rather than smoothed over. Jira has no fixed state set at
all: the statuses, their categories, the transitions between them and the resolutions
that close them are per-project configuration. So the core's seven states map onto
whatever this project's workflow defines, the mapping is written down per project rather
than assumed, and the two cases where it commonly fails — no review status, no parked
status — are named in `jira-issue-lifecycle` along with what to do instead of inventing
one.

## Configuration: the ticket-pattern note

`issue-tracker-core` shares one variable with the sibling `dev-guardrails` plugin so the
two agree on what an issue key looks like:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Regex for the issue-key shape, used to recover a key from a branch name, message or title. |

**Jira keys match that default natively, unchanged.** A Jira key is a project key —
uppercase letters and digits, beginning with a letter — a hyphen, and a number, which is
exactly the shape the default describes. This is the one tracker in the catalog where
there is nothing to configure: install the plugin, set nothing, and the gate finds
`PROJ-123` on a branch named `feature/PROJ-123-add-auth-middleware`.

That is worth saying out loud because the sibling `github-issues` adapter had to solve it.
GitHub issues are bare numbers written `#123` with no alphabetic prefix, so the default
matches nothing in a GitHub repository and the gate silently finds no key on a correctly
named branch. That adapter documents two resolutions — a synthetic `GH-` prefix, or a bare
`[0-9]+` pattern that matches every number anywhere including the `2` in `refactor/v2-parser`
— and requires each repository to pick one and write it down. None of that applies here.

Two caveats, because "works by default" is not "cannot be wrong":

- The default matches *any* project's key shape. In a repository referencing more than one
  Jira project, or containing a branch like `docs/RFC-2119-alignment`, it will match
  something that is not your issue. Tighten it per repository:
  `CLAUDE_TICKET_PATTERN=<PROJECT_KEY>-[0-9]+`.
- Matching the pattern is not evidence the issue exists. Fetch it.

## Every numeric identifier is configuration, not content

Issue-type ids, transition ids, status ids, priority ids, resolution ids, field ids of the
form `customfield_NNNNN`, the site's Cloud ID, board ids, sprint ids and project keys all
differ per Jira instance. A value correct on one site is wrong on another and is often
*accepted* on another, because the numbers collide — which is how you end up with a Task
where you meant a Bug and no error anywhere.

**So this plugin ships none of them.** It ships the endpoint that enumerates each one on
your own site: `createmeta/<PROJECT_KEY>/issuetypes` for issue types, `/field` for field
ids, `/issue/<KEY>/transitions` for transitions, `/status` and `/statuscategory` for
statuses, `/myself` for your own `accountId`, `/rest/agile/1.0/board` for boards. The
plugin root `SKILL.md` has the full table.

That is the same argument `parent-child-hygiene` makes about the candidate-parent list,
one level down: a cached value is wrong within weeks, is trusted while wrong, and a
staleness note only makes the staleness documented.

## Dependencies

- `issue-tracker-core` — supplies the pre-work gate, the branch and title conventions, the
  status vocabulary, the parent-child rules and the issue-as-record rule that every skill
  here carries out.

## License

MIT
