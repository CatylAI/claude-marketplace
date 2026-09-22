---
name: projects-v2
description: "Read and write a GitHub Projects v2 board from the command line, which is GraphQL-only — resolve a project node id from owner and number, list fields and single-select option ids, page through items 100 at a time with the after/pageInfo idiom, add an issue with addProjectV2ItemById, and set its status with updateProjectV2ItemFieldValue. Use when a project board carries the real status vocabulary, when a sweep must read every item, or when gh returns a scope error on a project query."
license: MIT
---

# Projects v2

A Projects v2 single-select status field is the honest carrier for the core's
`status-vocabulary` on GitHub: it holds exactly one option, so the conflicting-label
problem in `triage-and-labels` cannot occur. The price is that everything here is
GraphQL.

## There is no REST API for Projects v2

Classic Projects had `/projects`, `/columns`, `/cards`. Projects v2 has none of
that. Every read and every write goes through the GraphQL endpoint:

```
gh api graphql -f query='...'
```

Two flag forms matter and mixing them up is the most common first failure:

| Flag | Sends | Use for |
| --- | --- | --- |
| `-f name=value` | A string | `ID!` and `String!` variables — node ids, option ids, logins |
| `-F name=value` | Type-converted (numbers become integers, `true`/`false` become booleans) | `Int!` variables — project numbers, issue numbers |

A `Int!` variable passed with `-f` fails with a type error that names the
variable, which is at least a legible error. The reverse — an `ID!` passed with
`-F` — can silently coerce a numeric-looking id and is harder to spot.

## Auth: the scope a default login does not grant

`gh auth login` requests `repo`, `read:org`, `gist` and `workflow`. It does not
request `project`. Every query below will fail until you add it.

Check what you have:

```
gh auth status
```

That prints the token's scopes. If neither `project` nor `read:project` is in the
list, add one:

```
gh auth refresh -s project
```

`project` grants read and write; `read:project` is read-only and is the right
choice for a sweep that only reports. Use `-s read:project` for that.

The error you get without it is specific, and recognising it saves debugging the
query:

```
GraphQL: Your token has not been granted the required scopes to execute this
query. The 'projectV2' field requires one of the following scopes:
['read:project'], but your token has only been granted the: ['repo', ...] scopes.
```

That message means the query is correct and the token is not. Do not rewrite the
query. Separately: for an organisation project, the organisation may also require
the token's OAuth app or SSO authorisation — `gh auth status` reports SSO state,
and a `Resource not accessible by personal access token` on an org project with a
valid `project` scope points there rather than at the scope.

## Step 1 — Resolve the project node id

Every other call takes the project's node id (`PVT_...`), which is not the number
in the board's URL. Resolve it once per session.

Organisation-owned project:

```
gh api graphql -f query='
  query($login: String!, $number: Int!) {
    organization(login: $login) {
      projectV2(number: $number) {
        id
        title
        url
      }
    }
  }' -f login=<owner> -F number=7 --jq '.data.organization.projectV2'
```

User-owned project — same shape, different root field:

```
gh api graphql -f query='
  query($login: String!, $number: Int!) {
    user(login: $login) {
      projectV2(number: $number) {
        id
        title
        url
      }
    }
  }' -f login=<owner> -F number=7 --jq '.data.user.projectV2'
```

`null` under `organization` when the owner is a user account (or the reverse) is
the usual cause of an otherwise inexplicable empty result. There is no root field
that accepts either; pick the one matching the owner type.

Keep the id in a shell variable for the rest of the session:

```
project_id=$(gh api graphql -f query='
  query($login: String!, $number: Int!) {
    organization(login: $login) { projectV2(number: $number) { id } }
  }' -f login=<owner> -F number=7 --jq '.data.organization.projectV2.id')
```

List the owner's projects when you do not know the number:

```
gh api graphql -f query='
  query($login: String!) {
    organization(login: $login) {
      projectsV2(first: 20) {
        nodes { number title id url closed }
      }
    }
  }' -f login=<owner> --jq '.data.organization.projectsV2.nodes[] | "\(.number)\t\(.title)\t\(.id)\tclosed=\(.closed)"'
```

`closed` is the project's own liveness flag. A closed project is not a valid
destination for new work, the same way a closed milestone is not — the core's
liveness rule applies to the container whatever GitHub calls it.

## Step 2 — List the fields and read the option ids

A single-select update needs three ids: the project, the field, and the **option**.
The option id is not the option's name and is not derivable from it. Read it:

```
gh api graphql -f query='
  query($project: ID!) {
    node(id: $project) {
      ... on ProjectV2 {
        fields(first: 50) {
          nodes {
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              id
              name
              options { id name }
            }
            ... on ProjectV2IterationField {
              id
              name
              configuration {
                iterations { id title startDate duration }
              }
            }
          }
        }
      }
    }
  }' -f project="$project_id" --jq '.data.node.fields.nodes'
```

The `fields` connection returns a union, so every selection must sit inside an
inline fragment — a bare `{ id name }` on the connection's nodes is a schema
error, not a shortcut. `ProjectV2FieldCommon` is the interface every field type
implements, which is why the first fragment covers plain fields without
enumerating each concrete type.

Pull out just the Status field and its options:

```
gh api graphql -f query='
  query($project: ID!) {
    node(id: $project) {
      ... on ProjectV2 {
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            name
            options { id name }
          }
        }
      }
    }
  }' -f project="$project_id" --jq '.data.node.field'
```

Output looks like:

```
{
  "id": "PVTSSF_lADOAbCdEf4AbCdEzgXYZ123",
  "name": "Status",
  "options": [
    { "id": "f75ad846", "name": "Todo" },
    { "id": "47fc9ee4", "name": "In Progress" },
    { "id": "98236657", "name": "Done" }
  ]
}
```

Those eight-character option ids are what the update mutation takes. Map them
onto the core's vocabulary explicitly — a board whose options are "Todo / In
Progress / Done" collapses backlog with ready, and in review with in progress,
and `status-vocabulary` says exactly one state must mean "waiting on a reviewer".
Either add the options the vocabulary needs, or record the collapse in the
repository's own docs so nobody reads more into "In Progress" than it carries.

**Do not cache the option ids in a skill, a config file or a memory note.** They
change when someone edits the field, and the failure mode — writing a stale
option id — is a mutation that errors or, on a recreated option, silently sets
the wrong state. Re-read them in the same script run that uses them. This is the
core's "the list is a query" rule applied to field options.

## Step 3 — List the items, all of them

Connections cap at 100 per page. A sweep that reads page one and reports a result
is wrong, not partial — it will report a clean board because the dirty items were
on page two.

Two ways to page. Prefer the first.

### `--paginate`, which requires the `$endCursor` idiom

`gh api graphql --paginate` walks the pages itself, but only if the query
declares a variable named exactly `$endCursor` and selects
`pageInfo { hasNextPage endCursor }` on the connection being paged:

```
gh api graphql --paginate -f query='
  query($project: ID!, $endCursor: String) {
    node(id: $project) {
      ... on ProjectV2 {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            content {
              ... on Issue {
                number
                title
                url
                state
                repository { nameWithOwner }
              }
              ... on PullRequest { number title url state }
              ... on DraftIssue { title }
            }
            fieldValues(first: 20) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  optionId
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldTextValue {
                  text
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldNumberValue {
                  number
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldDateValue {
                  date
                  field { ... on ProjectV2FieldCommon { name } }
                }
                ... on ProjectV2ItemFieldIterationValue {
                  title
                  startDate
                  field { ... on ProjectV2FieldCommon { name } }
                }
              }
            }
          }
        }
      }
    }
  }' -f project="$project_id"
```

The variable name is not arbitrary and the requirement is easy to miss: rename it
to `$cursor` and `--paginate` stops paging without saying so. One page comes back
and the command exits zero.

`--paginate` emits one JSON document per page, so a `--jq` filter runs per page.
That is fine for line-oriented output and wrong for anything that aggregates —
`--jq 'length'` gives you a count per page, not a total. Aggregate downstream:

```
gh api graphql --paginate -f query='...' \
  --jq '.data.node.items.nodes[] | select(.content.number != null) |
        [ (.content.number|tostring),
          ([.fieldValues.nodes[] | select(.field.name == "Status") | .name] | first // "no status"),
          .content.title ] | @tsv'
```

### Manual paging, when you need per-page control

```
cursor=null
while : ; do
  page=$(gh api graphql -f query='
    query($project: ID!, $after: String) {
      node(id: $project) {
        ... on ProjectV2 {
          items(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { id content { ... on Issue { number title state } } }
          }
        }
      }
    }' -f project="$project_id" -f after="$cursor")
  printf '%s\n' "$page" | jq -r '.data.node.items.nodes[] | select(.content.number) | "#\(.content.number)\t\(.content.state)\t\(.content.title)"'
  [ "$(printf '%s' "$page" | jq -r '.data.node.items.nodes | length')" -eq 0 ] && break
  [ "$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.hasNextPage')" = "true" ] || break
  cursor=$(printf '%s' "$page" | jq -r '.data.node.items.pageInfo.endCursor')
done
```

The loop terminates on `hasNextPage: false`, never on an item count — a page can
legitimately come back short.

Report the item count you actually read alongside any sweep result. "17 items, no
status set" is a finding; "no status set" with no denominator is not checkable.

## Step 4 — Add an issue to the project

`addProjectV2ItemById` takes the issue's **GraphQL node id** as `contentId`. Not
its number, and not its REST database id — see the id table in
`milestones-and-sub-issues` for all three.

```
content_id=$(gh issue view 123 --json id --jq .id)

gh api graphql -f query='
  mutation($project: ID!, $content: ID!) {
    addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
      item { id }
    }
  }' -f project="$project_id" -f content="$content_id" --jq '.data.addProjectV2ItemById.item.id'
```

That returns the **item id** (`PVTI_...`), which is the handle for field updates.
An item id is per-project: the same issue on two boards has two item ids.

The mutation is idempotent in effect — adding an issue already on the board
returns the existing item id rather than creating a duplicate — so it is safe in
a loop.

Removing an item:

```
gh api graphql -f query='
  mutation($project: ID!, $item: ID!) {
    deleteProjectV2Item(input: {projectId: $project, itemId: $item}) {
      deletedItemId
    }
  }' -f project="$project_id" -f item="$item_id"
```

This removes the card, not the issue.

## Step 5 — Set the status

```
gh api graphql -f query='
  mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $project
        itemId: $item
        fieldId: $field
        value: { singleSelectOptionId: $option }
      }
    ) {
      projectV2Item { id }
    }
  }' \
  -f project="$project_id" \
  -f item="PVTI_lADOAbCdEf4AbCdEzgABC123" \
  -f field="PVTSSF_lADOAbCdEf4AbCdEzgXYZ123" \
  -f option="47fc9ee4"
```

The `value` input is a one-of: exactly one key, matching the field's type.

| Field type | `value` key | Example |
| --- | --- | --- |
| Single select | `singleSelectOptionId` | `{ singleSelectOptionId: "47fc9ee4" }` |
| Text | `text` | `{ text: "needs design input" }` |
| Number | `number` | `{ number: 3 }` |
| Date | `date` | `{ date: "2026-03-31" }` |
| Iteration | `iterationId` | `{ iterationId: "a1b2c3d4" }` |

Clearing a field is a different mutation — `clearProjectV2ItemFieldValue`, same
input minus `value`. Passing `null` to `updateProjectV2ItemFieldValue` is
rejected.

**Verify the write.** The core requires reading back anything automation claimed
to do, and a mutation that returns an item id has told you nothing about the
value:

```
gh api graphql -f query='
  query($item: ID!) {
    node(id: $item) {
      ... on ProjectV2Item {
        fieldValues(first: 20) {
          nodes {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              field { ... on ProjectV2FieldCommon { name } }
            }
          }
        }
      }
    }
  }' -f item="$item_id" --jq '.data.node.fieldValues.nodes[] | select(.name != null)'
```

## The `gh project` convenience commands

`gh` ships a `project` command group that wraps some of the above without a
hand-written query:

```
gh project list --owner <owner>
gh project view 7 --owner <owner>
gh project field-list 7 --owner <owner> --format json
gh project item-list 7 --owner <owner> --format json --limit 500
gh project item-add 7 --owner <owner> --url https://github.com/<owner>/<repo>/issues/123
gh project item-edit --id <item-id> --project-id <PVT_...> --field-id <PVTSSF_...> --single-select-option-id <option-id>
```

These are genuinely easier for one-off work, and `item-list --limit` handles
paging for you. Two reasons the GraphQL forms above remain the reference:

- The flag set has changed across `gh` releases more than the GraphQL schema has.
  **Check `gh project item-edit --help` on your installed version before scripting
  against these**, rather than assuming the flags above match.
- Anything the wrapper does not expose — a filtered field selection, a multi-field
  read in one round trip, an aggregate across pages — has to be a query anyway.

## Rate limits are a points budget, not a request count

REST gives you 5,000 requests per hour. GraphQL gives you a points budget, also
nominally 5,000 per hour, where one request costs between 1 point and many
depending on how many nodes it could return. A single `items(first: 100)` with
nested `fieldValues(first: 20)` is not a 1-point request.

Ask the query what it costs — `rateLimit` can be selected alongside anything
else:

```
gh api graphql -f query='{ rateLimit { limit cost remaining resetAt } }'
```

Embedded in a real query, so you learn the cost of the thing you are actually
running:

```
gh api graphql -f query='
  query($project: ID!, $endCursor: String) {
    rateLimit { cost remaining resetAt }
    node(id: $project) {
      ... on ProjectV2 {
        items(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { id }
        }
      }
    }
  }' -f project="$project_id" --jq '.data.rateLimit'
```

`cost` is for the request just made; `remaining` is the budget left in the
window; `resetAt` is when it refills. A paging loop should read `remaining` each
iteration and stop rather than grinding into a 403. Reducing `first:` reduces
cost — that is the lever, more than reducing the number of requests.

`gh api graphql` does not retry on secondary rate limits. A burst of mutations in
a loop can trip one even with budget remaining; space them out.

## When a field name here is wrong

The Projects v2 schema has moved more than most of GitHub's API, and a
confidently wrong query is worse than a flagged uncertain one. Ask the schema
rather than guessing:

```
gh api graphql -f query='
  { __type(name: "ProjectV2") { fields { name description } } }' --jq '.data.__type.fields[].name'
```

```
gh api graphql -f query='
  { __type(name: "ProjectV2ItemFieldValue") { possibleTypes { name } } }'
```

```
gh api graphql -f query='
  { __type(name: "UpdateProjectV2ItemFieldValueInput") { inputFields { name type { name kind ofType { name } } } } }'
```

**Verified on github.com, 2026-09-22** (`gh` 2.93.0, schema introspection):
`ProjectV2.field(name:)`, `clearProjectV2ItemFieldValue` and
`updateProjectV2ItemFieldValue` all exist, and `gh project` ships `field-list`,
`item-list`, `item-add` and `item-edit` with the `--single-select-option-id`
flag used above.

The scope requirement was confirmed the hard way: with a token carrying
`repo`, `workflow`, `admin:org`, `gist` and `delete_repo` but no project scope,
`gh project list` fails with `your authentication token is missing required
scopes [read:project]`. Note that raw `gh api graphql` queries against the same
token can still succeed, so a working GraphQL call is not evidence that the CLI
path will work.

Still worth checking against your own deployment before scripting:

- Everything above on **GitHub Enterprise Server**, which lags github.com.
  Fall back to filtering the `fields(first: 50)` list if `field(name:)` is absent.
- Whether `projectsV2` on an organisation accepts the filtering arguments your
  version of the docs shows; the argument set has grown over time.
