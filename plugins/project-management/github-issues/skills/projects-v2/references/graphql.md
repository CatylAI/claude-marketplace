# Projects v2 over GraphQL

For what the `gh project` commands do not expose: a filtered multi-field read in one round trip,
an aggregate across pages, clearing a field on an older `gh`, or a GitHub Enterprise Server
deployment whose `gh` lacks the newer flags. Projects v2 has no REST API; every call goes through
`gh api graphql`.

Shell variables do not survive between Bash calls. Every example writes ids literally
(`PVT_…`, `PVTI_…`, `PVTSSF_…`); substitute the values you read in the earlier step.

## Contents

- [Variables: -f versus -F](#variables--f-versus--f)
- [Resolve the project node id](#resolve-the-project-node-id)
- [Fields and option ids](#fields-and-option-ids)
- [Read every item](#read-every-item)
- [Add and remove an item](#add-and-remove-an-item)
- [Set or clear a field](#set-or-clear-a-field)
- [Read a write back](#read-a-write-back)
- [Cost: a points budget](#cost-a-points-budget)
- [When a field name is wrong](#when-a-field-name-is-wrong)

## Variables: -f versus -F

| Flag | Sends | Use for |
|---|---|---|
| `-f name=value` | A string | `ID!` and `String!` variables: node ids, option ids, logins |
| `-F name=value` | Converted: integers, `true`/`false`, `null` | `Int!` variables: project and issue numbers |

An `Int!` passed with `-f` fails with a type error naming the variable.

## Resolve the project node id

Every mutation takes the project's node id (`PVT_…`), not the number in the board URL. An
organization project:

```bash
gh api graphql -f query='
  query($login: String!, $number: Int!) {
    organization(login: $login) { projectV2(number: $number) { id title url closed } }
  }' -f login=<owner> -F number=7 --jq '.data.organization.projectV2'
```

For a personal-account project, replace `organization` with `user` in the query and the `--jq`
path. A `null` result usually means the owner type is the other one; no root field accepts both.

`gh project view 7 --owner <owner> --format json --jq .id` returns the same id without a query.

## Fields and option ids

The `fields` connection returns a union, so every selection sits in an inline fragment;
`ProjectV2FieldCommon` is the interface every field type implements:

```bash
gh api graphql -f query='
  query($project: ID!) {
    node(id: $project) {
      ... on ProjectV2 {
        fields(first: 50) {
          nodes {
            ... on ProjectV2FieldCommon { id name dataType }
            ... on ProjectV2SingleSelectField { options { id name } }
            ... on ProjectV2IterationField { configuration { iterations { id title startDate duration } } }
          }
        }
      }
    }
  }' -f project=PVT_kwDOAbCdEf4AbCdE --jq '.data.node.fields.nodes'
```

Only the Status field:

```bash
gh api graphql -f query='
  query($project: ID!) {
    node(id: $project) {
      ... on ProjectV2 {
        field(name: "Status") { ... on ProjectV2SingleSelectField { id name options { id name } } }
      }
    }
  }' -f project=PVT_kwDOAbCdEf4AbCdE --jq '.data.node.field'
```

If `field(name:)` is missing on an older Enterprise Server, filter the `fields(first: 50)` list.

## Read every item

Connections return at most 100 nodes per page. `--paginate` walks the pages only when the query
declares a variable named exactly `$endCursor` and selects `pageInfo { hasNextPage endCursor }` on
the paged connection. Under any other variable name it returns page one and exits zero.

```bash
gh api graphql --paginate -f query='
  query($project: ID!, $endCursor: String) {
    node(id: $project) {
      ... on ProjectV2 {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content {
              ... on Issue { number title state repository { nameWithOwner } }
              ... on PullRequest { number title state }
              ... on DraftIssue { title }
            }
            status: fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
          }
        }
      }
    }
  }' -f project=PVT_kwDOAbCdEf4AbCdE \
  --jq '.data.node.items.nodes[] | [(.content.number // "draft" | tostring), (.status.name // "no status"), .content.title] | @tsv'
```

`--jq` runs once per page, so `--jq 'length'` counts per page. To aggregate, add `--slurp` and drop
`--jq`, then process the array of pages with `jq` in the same Bash call. Report the number of items
read alongside any finding.

## Add and remove an item

`addProjectV2ItemById` takes the issue's GraphQL node id as `contentId`
(`gh issue view 123 --json id --jq .id`), not its number or REST id:

```bash
gh api graphql -f query='
  mutation($project: ID!, $content: ID!) {
    addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
  }' -f project=PVT_kwDOAbCdEf4AbCdE -f content=I_kwDOAbCdEf4AbCdEf --jq '.data.addProjectV2ItemById.item.id'
```

It returns the item id (`PVTI_…`), which is per project: the same issue on two boards has two item
ids. Remove the card (not the issue):

```bash
gh api graphql -f query='
  mutation($project: ID!, $item: ID!) {
    deleteProjectV2Item(input: {projectId: $project, itemId: $item}) { deletedItemId }
  }' -f project=PVT_kwDOAbCdEf4AbCdE -f item=PVTI_lADOAbCdEf4AbCdEzgABC123
```

## Set or clear a field

```bash
gh api graphql -f query='
  mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $project, itemId: $item, fieldId: $field,
      value: { singleSelectOptionId: $option }
    }) { projectV2Item { id } }
  }' -f project=PVT_kwDOAbCdEf4AbCdE -f item=PVTI_lADOAbCdEf4AbCdEzgABC123 \
     -f field=PVTSSF_lADOAbCdEf4AbCdEzgXYZ123 -f option=47fc9ee4
```

`value` takes exactly one key, matching the field type:

| Field type | Key | Example |
|---|---|---|
| Single select | `singleSelectOptionId` | `{ singleSelectOptionId: "47fc9ee4" }` |
| Text | `text` | `{ text: "needs design input" }` |
| Number | `number` | `{ number: 3 }` |
| Date | `date` | `{ date: "2026-03-31" }` |
| Iteration | `iterationId` | `{ iterationId: "a1b2c3d4" }` |

Clearing is a separate mutation, `clearProjectV2ItemFieldValue`, with the same input minus `value`.

## Read a write back

A mutation that returns an item id says nothing about the value:

```bash
gh api graphql -f query='
  query($item: ID!) {
    node(id: $item) {
      ... on ProjectV2Item {
        status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
      }
    }
  }' -f item=PVTI_lADOAbCdEf4AbCdEzgABC123 --jq '.data.node.status.name'
```

## Cost: a points budget

GraphQL rate limits count points, not requests; a request's cost grows with how many nodes it could
return, so `items(first: 100)` with nested connections costs more than one point. Select
`rateLimit` next to any query to see its cost:

```bash
gh api graphql -f query='{ rateLimit { limit cost remaining resetAt } }'
```

A paging loop should check `remaining` and stop before it runs out. Lowering `first:` lowers cost.
A burst of mutations can also trip a secondary rate limit even with budget left, so space them out.
Current limits: the GitHub GraphQL "Rate limits and node limits" page.

## When a field name is wrong

The Projects v2 schema has changed more than most of GitHub's API. Ask the schema rather than
guessing:

```bash
gh api graphql -f query='{ __type(name: "ProjectV2") { fields { name } } }' --jq '.data.__type.fields[].name'
gh api graphql -f query='{ __type(name: "UpdateProjectV2ItemFieldValueInput") { inputFields { name } } }'
```

GitHub Enterprise Server lags github.com; check there before scripting against it.
