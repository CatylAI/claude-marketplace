# The Datadog incident record

`observability-core:incident-declaration` owns what the record says: the declaration and
update template, the severity table, the state set and the close-out checklist. This file maps
those onto Datadog Incident Management fields. The REST calls are in the
`datadog-monitors-and-queries` skill's `references/rest-api.md`, "Incidents".

## Severity and state

| Core value | Datadog field | Default Datadog value |
|---|---|---|
| Sev1 … Sev4 | `fields.severity` (dropdown) | `SEV-1` … `SEV-4` (the default list runs to `SEV-5`) |
| `declared` | `fields.state` (dropdown) | `active` |
| `mitigated` | `fields.state` | `stable`: no longer affecting users, investigation incomplete |
| `resolved` | `fields.state` | `resolved` |
| `closed` | `fields.state` | `completed` if the organization enabled it; otherwise stay `resolved` and record the close-out in the timeline |

Severity and status values are configurable per organization in Incident Settings. Read the
values an existing incident uses before writing new ones, and use the org's own when they
differ from the defaults.

## Fields that record the event

| Datadog field | Core close-out item | Filled means |
|---|---|---|
| `title` | Symptom | Service, symptom and, once known, the cause in a clause. Not "investigating errors". |
| `customer_impacted` + `customer_impact_scope` | Affected populations | Answered, not defaulted. The scope is required whenever `customer_impacted` is true; write it from the blast-radius block. |
| `detected` | Corrected detection time | When a person or monitor first knew. The API sets it to the create time; correct it straight away, or time-to-detect is wrong in every report that reads this incident. |
| `customer_impact_start` / `customer_impact_end` | Corrected impact-start time | From the metric boundary, not the alert. The gap between impact start and `detected` is the detection gap. |
| `fields.severity` | Severity history | Current value; each change also noted in the timeline with the reason. |
| `fields.state` | State | See the table above. |
| `fields.summary` | Blast-radius block, mitigation | The latest blast-radius block, the mitigation and its effect. |
| `fields.services` | Affected services | Every affected service plus the upstream that caused it. |
| `fields.root_cause` (if defined) | Root cause | The mechanism, plus the hypotheses disproved and the evidence that disproved them: a later responder with the same symptom forms the same wrong theory. |
| `fields.detection_method` (if defined) | How it was detected | Accurate, including "customer report" or "engineer", which admits that monitoring missed it. Carry that into a follow-up. |
| Responders | Roles | Everyone who responded, including reviewers of the fix. |
| Attachments | Links | The fixing change, the tracker items, the monitor or dashboard that showed it. |
| Todos (`/relationships/todos`) | Follow-ups | One todo per follow-up, each containing the tracker key. The tracker item is the owned work; the todo is the link back. |

`summary`, `root_cause` and `detection_method` are organization-defined fields, so their keys
and types can differ. An existing incident read with `get_datadog_incident` or
`GET /api/v2/incidents/<INCIDENT_UUID>` shows the keys this org uses.

A field you could not fill gets "not known: <why>", per the core close-out rule.

## Posting updates

The public API has no endpoint for adding timeline notes after creation (only
`initial_cells` at create time), and the MCP server has no incident-write tool. So:

- Put the latest core update (Impact, Known, Trying, Next update) into `fields.summary` with a
  `PATCH`, replacing the previous one; the blast-radius block goes there too.
- Ask the user, or the IC, to post each update to the incident timeline from the Datadog UI or
  the incident's chat integration, which keeps the history the summary field overwrites.
- Confirm by re-reading the incident. `get_datadog_incident` does not return the timeline, so
  check the timeline in the UI.
