# datadog-observability

The Datadog adapter for `observability-core`. It runs core's incident declaration, blast radius
and production triage against a Datadog organization: which Datadog source answers each
question, the query traps that make a Datadog number mean something else, and how core's
incident record maps onto Datadog Incident Management.

The judgement stays in `observability-core`. Nothing here changes when to declare, how severity
is chosen or how a sweep is ranked; this layer answers how to get each number out of Datadog.

## What ships

| Name | Type | Use it when | Surfaces |
|---|---|---|---|
| `datadog-incident-response` | Skill | A Datadog-monitored service looks broken: confirm impact in three queries, fill core's blast-radius block from Datadog, check what changed, declare and maintain the Datadog incident. | Claude Code, Cowork, claude.ai |
| `datadog-monitors-and-queries` | Skill | You need a Datadog query that means what it claims, or a Datadog number looks wrong. Owns rollup, `.as_count()`, denominators, the `env` versus `@env` trap, exclusion filters and `notify_no_data`. Read-only. | Claude Code, Cowork, claude.ai |
| `dd-prod-triage` | Skill | Sweeping Datadog Error Tracking and error logs into core's ranked proposal set. | Claude Code, Cowork, claude.ai |
| `dd-investigator` | Subagent | One bounded question answered read-only, without the main session holding the query output. | Claude Code only |

Reference files the skills load on demand:

- `skills/datadog-monitors-and-queries/references/setup.md`: the Datadog capability rows for
  your `CLAUDE.md`, transport choice, MCP tool map, credentials and site, access check.
- `skills/datadog-monitors-and-queries/references/rest-api.md`: every REST call, for sessions
  without the Datadog MCP tools.
- `skills/datadog-incident-response/references/incident-record.md`: core severity and states
  mapped to Datadog fields, and the close-out field table.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install datadog-observability@catylai
```

`observability-core` is installed with it as a dependency.

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin. Only the skills load there;
`dd-investigator` does not run (see Surfaces).

## Connect Datadog

The skills use Datadog's official MCP tools when the session has them, REST with curl when it
does not, and pasted data when neither is available. Set up the first one you can:

1. **Claude Code: Datadog's plugin (recommended).**

   ```
   /plugin install datadog@claude-plugins-official
   ```

   Run `/ddsetup` to pick your Datadog site and log in with OAuth, then `/ddtoolsets` and enable
   `error-tracking` (it is not in the default toolset, and `dd-prod-triage` needs it). Enable
   `audit-trail` too if you want Datadog configuration edits checked during change correlation.
   If you had added the Datadog MCP server by hand, remove it first, as Datadog's setup guide
   asks.
2. **Claude apps and Cowork:** add the Datadog connector from the Claude connectors directory.
3. **Any other MCP client:** add the remote MCP endpoint for your site from Datadog's MCP server
   setup page, with `?toolsets=core,error-tracking`.
4. **REST fallback:** set these before starting the session. Use a service account's keys with
   read permissions only, unless you want the skill to declare incidents over REST.

   | Variable | Value |
   |---|---|
   | `DD_API_KEY` | API key |
   | `DD_APPLICATION_KEY` | Application key (reads need it) |
   | `DD_SITE` | Your site, for example `datadoghq.com` or `datadoghq.eu` |

   These are the variable names Datadog's plugin reads for key authentication. Version 0.1.0 of
   this plugin used `DD_APP_KEY`; rename it.

This plugin ships no `.mcp.json`. Datadog's endpoint depends on your site and your choice of
OAuth or keys, and its plugin and connector already handle both; a second, bundled server would
conflict with them.

Datadog's MCP server has no tool for creating or updating incidents, so declaring over the API
always uses REST. Without REST credentials, the skill tells you to declare in the Datadog UI and
prints the filled template.

## Tell it where your telemetry lives

Add the `## Observability capabilities` section that `observability-core` reads to your
project's `CLAUDE.md`. The Datadog version of the rows, with the traps each row should record
(the reserved `env` tag, services missing from Error Tracking, indexes with exclusion filters),
is in `skills/datadog-monitors-and-queries/references/setup.md`. When the section is missing,
the skills ask for the rows and carry on.

## Surfaces

- **Claude Code (terminal, desktop, IDE):** everything works. With Datadog's plugin the skills
  query through MCP; with the three environment variables they use curl.
- **Claude Code on the web:** has a shell in a cloud container, so the curl fallback works once
  the environment provides credentials and network access. Add `DD_API_KEY`,
  `DD_APPLICATION_KEY` and `DD_SITE` in the cloud environment's settings, and allow
  `api.<your site>` under its network access. Without them the skills fall back to pasted data.
- **Cowork and the Claude apps:** the three skills load. With the Datadog connector they query
  through MCP; without it they work from what you paste (exports, counts, metric values with
  their query and rollup). `dd-investigator` is not available there.

`dd-investigator` is a subagent, and subagents run only in Claude Code. It was kept as an agent
because its purpose is context isolation: a hundred log lines go through its window instead of
the main session's. On other surfaces, ask the main session the same question.

## Read-only, with two deliberate writes

Reads never change anything. The writes the skills can propose, each only with your explicit
approval:

- declaring and amending a Datadog incident (`datadog-incident-response`), because declaring
  is core's first rule;
- changing an Error Tracking issue's state or links (`dd-prod-triage`), with a written reason
  and a revisit date for `IGNORED` or `EXCLUDED`.

`dd-investigator` is read-only by instruction: it has no Write or Edit tool, but it has Bash
(which a plugin agent's tool list cannot narrow to read-only commands) and whole Datadog MCP
servers, write tools included. For enforced read-only, give it credentials that cannot write: a Datadog role without `mcp_write`
(Datadog rejects every MCP write tool for such a role) and REST keys from a read-only service
account, and keep your Claude Code permission rules prompting for `curl`.

The agent's tool list names Datadog MCP servers by the names Datadog documents (`datadog`,
`datadog-mcp`, and the plugin's own). A server you added under another name is invisible to the
agent; the agent then uses REST.

## Dependencies

`observability-core`, for the incident-declaration, blast-radius and production-triage
procedures and templates these skills execute. Tracker filing goes through whatever tracker
tool the session has, per core's production-triage Phase 5.

## Layout

```
datadog-observability/
├── .claude-plugin/plugin.json
├── README.md
├── agents/dd-investigator.md
└── skills/
    ├── datadog-incident-response/
    │   ├── SKILL.md
    │   └── references/incident-record.md
    ├── datadog-monitors-and-queries/
    │   ├── SKILL.md
    │   └── references/
    │       ├── setup.md
    │       └── rest-api.md
    └── dd-prod-triage/SKILL.md
```

## License

MIT
