# datadog-observability

The Datadog adapter for `observability-core`. Concrete queries and API calls for
incident response and production triage against a Datadog organization.

The judgement lives in the core. Nothing here changes *when* to declare an
incident, how severity is chosen, or what outranks what in a triage sweep. This
layer answers only: how do I get that number out of Datadog.

## When to use it

- An incident is open and you need blast radius as a real number rather than an
  impression.
- You need a Datadog query that works on the first try, mid-incident.
- You are sweeping a window of production errors into tracked work.
- A graph and an API call disagree and you need to know which is lying.

## When not to use it

- **Deciding whether to declare.** That is `observability-core`'s
  `incident-declaration`. Read it first; come back here for the queries.
- **Writing the postmortem.** `incident-postmortem` in the `ops-workflows`
  plugin owns the blameless write-up, timeline format and action-item table.
  This plugin covers the live phase and hands off at resolution.
- **Filing tracked work.** `dd-prod-triage` produces a proposal set and stops.
  Pair with a tracker adapter — `jira-tracker` or `github-issues`.

## Prerequisites

Two credentials, both from environment variables or an `op://` reference and
never a literal in any file:

```bash
echo "${DD_API_KEY:+DD_API_KEY is set}"
echo "${DD_APP_KEY:+DD_APP_KEY is set}"
```

Most read endpoints need **both**. A request with only `DD-API-KEY` returns a
`403` that reads like a permissions problem and is usually a missing application
key — worth recognising, because the obvious next step is to go asking for
permissions you already have.

You also need your **site**. Datadog runs several and the API host differs per
region: `api.datadoghq.com`, `api.datadoghq.eu`, `api.us3.datadoghq.com`,
`api.us5.datadoghq.com`, `api.ap1.datadoghq.com`, `api.ddog-gov.com` and others.
A call to the wrong host authenticates against an organization that does not
contain your data and returns an empty result rather than an error.

## Install

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install datadog-observability@catylai
```

`observability-core` comes with it as a dependency.

## What's inside

| Name | Type | Purpose | Available |
|------|------|---------|-----------|
| `datadog-incident-response` | Skill | Confirm impact, measure blast radius from real metric queries, correlate against deploys, declare and maintain the incident record | both |
| `datadog-monitors-and-queries` | Skill | Metric and log query syntax, rollup semantics, monitor types, and the traps that make a number mean something else | both |
| `dd-prod-triage` | Skill | Sweep a window of errors into a ranked, deduplicated proposal set | both |
| `dd-investigator` | Subagent | One bounded investigative question, answered read-only, without the main session spending context on query output | Claude Code only |

## Surfaces

Skills load in both Claude Code and Cowork (Claude Code on the web).

**`dd-investigator` is a subagent and is unavailable in Cowork**, and every skill
here reaches the Datadog API over HTTPS with credentials from the environment —
which Cowork has no shell to provide. The procedures are readable on both
surfaces; executing them needs Claude Code.

## No MCP server, deliberately

This plugin ships no `.mcp.json`. Datadog publishes an MCP server, but this
marketplace is organised so that installing one vendor's adapter never drags in
another's transport — and an MCP server whose URL or auth shape this plugin
guessed wrong would fail at session start on every machine that installed it.
The API calls in these skills are explicit and need nothing but `curl` and two
environment variables.

If you run the Datadog MCP server, configure it yourself; these skills do not
depend on it either way.

## Two things worth knowing before you trust a number

**Log exclusion filters.** An index can be configured to drop or sample a class
of logs. Your query then returns a real number that is not the population. Check
the index configuration before reporting a log-derived count as a total.

**`notify_no_data`.** A monitor without it cannot tell "healthy" from "the agent
stopped reporting". Silence and success look identical, which is the same
degraded-versus-successful confusion the rest of this marketplace is built to
refuse.

## Dependencies

`observability-core`, for the incident-declaration, blast-radius and
production-triage procedures these skills execute.

## License

MIT.
