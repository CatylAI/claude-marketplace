# Observability capabilities: the project mapping

The skills in `observability-core` are written against capabilities (an error aggregator, a
metrics store, a deploy log) rather than products. Each project records its own answers once,
in its `CLAUDE.md`, so every session starts with them. The mapping lives in the project and not
in the plugin because an installed plugin is a cached copy that is replaced on every update.

## How the skills use it

1. Read the `## Observability capabilities` section of the project's `CLAUDE.md` (repository
   root, or `.claude/CLAUDE.md`). Use the rows the current step needs.
2. If the section is missing, or a needed row is empty, ask the user for those rows in one
   question and carry on with the answers. A row nobody can answer is recorded as `unknown`,
   and every number that depends on it is reported as `NOT MEASURED`, because an unmapped
   capability is a gap, not a zero.
3. After the incident or sweep, offer to add or complete the section with the template below.
   Write it only when the user agrees.

Without a checkout (web, or a session with no repository) there is no `CLAUDE.md` to read:
ask for the rows, or ask the user to paste the section.

## Template

Copy this into the project's `CLAUDE.md` and replace every `<…>`. Keep a row and write
`none` when the capability does not exist, so the gap stays visible.

```markdown
## Observability capabilities

| Capability | Where and how | Notes |
|---|---|---|
| Vendor adapter | <datadog-observability / gcp-observability / none> | Plugin that holds the concrete queries |
| Error aggregator | <tool or query that groups and counts errors by signature> | |
| Metrics store | <where request rate, error rate and latency percentiles live> | |
| Production tag | <exact literal that selects production, e.g. env:production> | Confirm it returns data |
| Deploy and change log | <every source of change: CI deploys, config, feature flags, infra> | List each repo that touches prod |
| Known gaps | <components whose logs the aggregator cannot reach, and where they live> | |
| Incident record | <incident tool, or a shared document location> | |
| Work tracker | <tracker, project and intake state for new items> | |
| Comms channel | <where responders coordinate and where stakeholders get updates> | |
```

## Which skill reads which rows

| Skill | Rows it needs |
|---|---|
| `incident-declaration` | Incident record, Comms channel, Work tracker (close-out) |
| `blast-radius` | Metrics store, Error aggregator, Production tag, Deploy and change log, Known gaps |
| `production-triage` | Error aggregator, Production tag, Known gaps, Work tracker, Vendor adapter |
