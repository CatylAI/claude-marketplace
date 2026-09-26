# jira-tracker

The Jira adapter for `issue-tracker-core`. The core states the rules (an advisory pre-work gate,
seven states, dedupe, parenting, the comment trail); this plugin makes them work against Jira
Cloud: fetching and creating issues, discovering transitions, keeping finished and abandoned
work apart with resolutions, JQL sweeps, and parent hygiene.

It works through Atlassian's Rovo MCP server when that is connected, falls back to the Jira
REST API v3 in Claude Code, and works from a pasted issue when neither is available.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install jira-tracker@catylai
```

In Claude Code, `issue-tracker-core` is a declared dependency and installs with it.

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin.

## Connect Jira

Pick one. The plugin bundles no MCP server, so it never asks you to sign in to something you
did not choose.

1. **Atlassian connector (recommended, every surface).** Add Atlassian at
   https://claude.ai/customize/connectors and sign in; on Team and Enterprise plans an admin
   adds it. Start a new session afterwards. Claude Code picks up claude.ai connectors when you
   are logged in with a claude.ai account.
2. **Atlassian MCP server in Claude Code only:**
   `claude mcp add --transport http atlassian https://mcp.atlassian.com/v2/mcp`, then `/mcp` in
   a session to sign in. Use this or the connector, not both.
3. **REST API token, Claude Code only.** Export `JIRA_SITE` (for example `yourco.atlassian.net`),
   `JIRA_EMAIL` and `JIRA_API_TOKEN` in the shell that launches Claude Code. With 1Password, run
   Claude Code under `op run -- claude` so `op://` references resolve.
4. **Nothing connected.** The skills ask you to paste the issue, run the same checks on it, and
   print every change for you to make in Jira.

The MCP server acts as you, within your Jira permissions. A Jira admin controls which of its
permission groups are enabled (`read_jira`, `write_jira` and `search_jira` by default) and
whether API-token auth is allowed.

For a read-only audit on the REST path, an account with Browse Projects is enough. Writes need
Create Issues, Edit Issues, Add Comments, Transition Issues or Assign Issues as appropriate.

## Tell it about your project

Add the `## Issue tracker` section from `issue-tracker-core` to your project's `CLAUDE.md`.
For Jira:

- `Tracker`: `jira-tracker`
- `Ticket pattern`: `<PROJECT_KEY>-[0-9]+`, for example `PROJ-[0-9]+`. The core default also
  matches Jira keys but catches other projects' keys and strings such as `RFC-2119` too.
- `Parent mechanism`: the `parent` field, with your level-1 type (usually Epic).
- `Status mapping`: your workflow's statuses against the seven core states, with the resolution
  that tells `done` from `declined`. `jira-issue-lifecycle` shows how to read the workflow and
  has a filled example.

## What's inside

| Skill | Use it when |
| --- | --- |
| `jira-issue-lifecycle` | Starting, pausing or finishing Jira-tracked work: fetch, create, assign, transition, comment on and close an issue for the pre-work gate and the comment trail. Covers the status mapping, resolutions, and how an issue moves on merge (explicit transition, automation rule or Smart Commits). |
| `jira-jql` | Finding issues: dedupe before filing, triage sweeps, the orphan sweep, live-parent queries. Read-only. |
| `epic-and-parent-hygiene` | Parenting a new issue, repairing orphans, auditing epics, and reading the project's hierarchy levels. |

References shipped with `jira-issue-lifecycle`:

- `references/atlassian-mcp.md`: connecting, the Jira tool names, `cloudId`, and calling rules.
- `references/rest-v3.md`: self-contained `curl` blocks for every operation, with tested Python
  helpers (Python 3.8 or later).
- `references/platform-changes.md`: dated facts to check against current docs, such as the
  removed search endpoint and Epic Link field, the MCP endpoint versions and tool renames, and
  Smart Commits.

## Surfaces

All three skills load in Claude Code and in Cowork. The plugin ships no agents, hooks or MCP
server.

| Access | Claude Code (including on the web) | Cowork and claude.ai |
| --- | --- | --- |
| Atlassian connector or MCP server | Yes | Yes (connector) |
| REST with an API token | Yes; on the web, only once the environment has the token and network access to your Jira site | No shell |
| Pasted issue | Yes | Yes |

## Not this plugin's job

- Pull and merge requests: `github-workflow` or `gitlab-workflow`. Branch and title shape:
  `issue-tracker-core:branch-and-title-conventions`.
- The rules themselves (states, dedupe, parenting, comment templates):
  `issue-tracker-core:tracker-discipline`.
- Jira administration: workflows, statuses, fields, automation rules, Smart Commit settings.
  The plugin reads configuration and never changes it.
- Confluence, Bitbucket and the rest of the Atlassian suite.

## Layout

```
jira-tracker/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    ├── jira-issue-lifecycle/
    │   ├── SKILL.md
    │   └── references/
    │       ├── atlassian-mcp.md
    │       ├── rest-v3.md
    │       └── platform-changes.md
    ├── jira-jql/SKILL.md
    └── epic-and-parent-hygiene/SKILL.md
```

## Dependencies

- `issue-tracker-core`: `pre-work-gate`, `branch-and-title-conventions` and `tracker-discipline`,
  whose rules every skill here carries out.

## License

MIT
