---
name: jira-jql
description: "JQL as the query language for every read against Jira — the search endpoint and its pagination, the clause and operator reference, statusCategory versus status, the triage sweeps for untriaged, unassigned, stale and lying issues, the orphan sweep, and the core's rule that a candidate-parent list is a live query and never a cached inventory. Use whenever you need to find issues in Jira: a triage pass, a backlog audit, a duplicate check before filing, or the shortlist of parents for a new issue."
license: MIT
when_to_use: "Any time a Jira question is 'which issues are...'. Also when a query returns zero rows and you cannot tell whether the backlog is clean or the JQL is wrong."
---

# JQL

Every read in this plugin is a JQL query. The gate's duplicate check, the
candidate-parent shortlist, the orphan sweep and every triage pass are all one
endpoint with a different expression in it.

Read this for the expression. Read `jira-issue-lifecycle` for what to do with
what comes back.

## The search endpoint, and the migration you will trip over

**Flagged as the single most movable thing in this document.** Jira Cloud
replaced its long-standing search endpoint with a token-paginated one, and the
two have different pagination contracts. Which of them your site accepts today is
something to verify rather than assume:

| Endpoint | Pagination | Status |
| --- | --- | --- |
| `GET`/`POST /rest/api/3/search` | `startAt` + `maxResults`, response carries `total` | The historical endpoint. Deprecated on Jira Cloud in favour of the one below; treat any example you find online that uses it — including older ones of ours — as dated. |
| `GET`/`POST /rest/api/3/search/jql` | `nextPageToken`, response carries **no** `total` | The current endpoint. |

Check which one answers on your site before building a sweep on top of it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql?jql=project%20%3D%20<PROJECT_KEY>&maxResults=1"
```

The current form, with the JQL passed safely rather than hand-encoded:

```bash
curl -sS -G -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
  --data-urlencode 'jql=project = <PROJECT_KEY> AND statusCategory != Done ORDER BY updated DESC' \
  --data-urlencode 'fields=summary,status,assignee,parent,issuetype,updated' \
  --data-urlencode 'maxResults=50'
```

`curl -G --data-urlencode` is the form to use throughout. Hand-encoding JQL into
a query string is where `!=`, spaces, quotes and `~` go wrong, and a mis-encoded
query does not error — it returns a different result set.

The POST form takes the same parameters as a JSON body and is easier to read once
the JQL gets long:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
  --data @- <<'JSON'
{
  "jql": "project = <PROJECT_KEY> AND statusCategory != Done ORDER BY updated DESC",
  "fields": ["summary", "status", "assignee", "parent", "issuetype", "updated"],
  "maxResults": 50
}
JSON
```

### Pagination, and the count that is no longer there

The token-paginated endpoint returns `nextPageToken` when more results exist.
Page until it is absent:

```bash
token=""
while :; do
  resp=$(curl -sS -G -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
    "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
    --data-urlencode 'jql=<YOUR JQL>' \
    --data-urlencode 'fields=summary,status' \
    --data-urlencode 'maxResults=100' \
    ${token:+--data-urlencode "nextPageToken=$token"})
  printf '%s' "$resp" | python3 -c 'import sys,json; [print(i["key"], i["fields"]["summary"]) for i in json.load(sys.stdin).get("issues",[])]'
  token=$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextPageToken","") or "")')
  [ -n "$token" ] || break
done
```

**The absence of `total` is a real change in what you can claim.** With the old
endpoint you could say "there are 47 orphans"; with the current one you can only
say "there are 47 orphans in the pages I read". If you need a count, there is a
dedicated endpoint for an approximation:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/approximate-count" \
  --data '{"jql": "<YOUR JQL>"}'
```

**Flagged:** verify that path on your site before relying on it. The word
*approximate* in its name is not decoration — quote it as approximate.

**A result count equal to your `maxResults` means you measured the limit, not the
population.** Page, or say which number you are quoting. Reporting a truncated
page as a complete sweep is how a backlog audit reports clean on a backlog it
only read the first hundred rows of.

## Clause reference

The clauses that carry almost every query in this plugin:

| Clause | Example | Notes |
| --- | --- | --- |
| `project` | `project = <PROJECT_KEY>` | Always include one. A query with no project scope reads every project you can see. |
| `issuetype` | `issuetype = Bug`, `issuetype in (Story, Task)` | By name here; by id in write calls. Names with spaces need quotes. |
| `status` | `status = "In Progress"` | The project's own status name. Configurable — see the category warning below. |
| `statusCategory` | `statusCategory != Done` | `To Do`, `In Progress`, `Done`. **This is the liveness filter.** |
| `resolution` | `resolution = EMPTY`, `resolution != EMPTY` | Where finished and abandoned actually differ. |
| `assignee` | `assignee = currentUser()`, `assignee IS EMPTY` | By `accountId` for a specific person, never by username. |
| `reporter` | `reporter = currentUser()` | |
| `parent` | `parent = <EPIC_KEY>`, `parent IS EMPTY` | The unified hierarchy field. See `epic-and-parent-hygiene` for when it is not the one your project uses. |
| `created` / `updated` / `resolved` | `updated < -14d`, `created >= startOfWeek()` | Relative (`-7d`, `-4w`) or `"yyyy/MM/dd"`. |
| `labels` | `labels = tech-debt`, `labels IS EMPTY` | Multi-valued. |
| `component` | `component = "ingestion"` | Company-managed projects only. |
| `priority` | `priority in (Highest, High)` | Names are per-site. |
| `sprint` | `sprint in openSprints()` | Requires a board; see the boards note. |
| `text` | `text ~ "connection reset"` | Searches summary, description, comments and more. The broadest free-text clause. |
| `summary` | `summary ~ "ingestion"` | `~` is a text match, not a substring match — see below. |
| `issuekey` | `issuekey in (PROJ-1, PROJ-2)` | Exact keys. |
| `ORDER BY` | `ORDER BY updated DESC` | Always order a sweep; an unordered page is not reproducible. |

### Operators and functions

| Construct | Meaning |
| --- | --- |
| `=` `!=` `>` `<` `>=` `<=` | Comparison. `!=` **excludes issues where the field is empty**, which surprises people on `assignee != currentUser()`. |
| `IN` / `NOT IN` | Set membership. |
| `IS EMPTY` / `IS NOT EMPTY` | The only correct way to test for an absent field. `= null` is not JQL. |
| `~` / `!~` | Text match. **Not a substring match** — it matches on indexed words, so `~ "time"` does not find `timeout`. Use `~ "time*"` for a prefix, and expect stemming and stop words to affect results. |
| `AND` `OR` `NOT` `()` | Boolean. Parenthesise every `OR` inside an `AND`; JQL precedence is not worth relying on memory for. |
| `WAS` / `WAS IN` / `CHANGED` | History clauses: `status CHANGED TO "In Progress" AFTER -7d`. Slower, and the highest-value way to find work that started and stalled. |
| `currentUser()` | The authenticated account. |
| `startOfDay()` `endOfWeek()` `startOfMonth()` | Boundary functions, with offsets: `startOfDay(-7)`. |
| `openSprints()` `closedSprints()` | Sprint state, board-dependent. |
| `membersOf("<group>")` | Group membership, for `assignee in membersOf(...)`. |

**Do not reach for `issueFunction`.** It reads like core JQL in search results and
is supplied by a third-party app, not by Jira. On a site without that app it is a
syntax error; on a site with it, a query that depends on it is not portable. If
you find yourself wanting it, the answer is usually two queries and a `comm`.

### `statusCategory`, not `status` — this is the one that bites

`status != Done` matches only the literal status *named* `Done`. Every other
terminal status in the workflow — declined, cancelled, won't do, duplicate,
deferred, and whatever this project calls them — passes straight through the
filter and lands in your result set.

`statusCategory != Done` filters on the category, which is one of three values
Jira guarantees and which every terminal status belongs to.

```
# Wrong — a name filter pretending to be a liveness filter
project = <PROJECT_KEY> AND issuetype = Epic AND status != Done

# Right — the category
project = <PROJECT_KEY> AND issuetype = Epic AND statusCategory != Done
```

`parent-child-hygiene` states the general rule: *filter on the state category,
not on a single state name, because most trackers have more than one terminal
state and a filter that excludes only the literal "done" one lets the others
through.* Jira is the tracker that rule was written about.

And the category filter is still not sufficient on its own. A project may have a
deferred or parked status that sits in the `To Do` or `In Progress` category and
is never a valid parent either. Exclude those explicitly, by name, because their
names are the only thing that identifies them:

```
project = <PROJECT_KEY> AND issuetype = Epic
  AND statusCategory != Done
  AND status NOT IN ("<DEFERRED_STATUS>", "<DECLINED_STATUS>")
ORDER BY updated DESC
```

Read the project's actual status set once — `GET /rest/api/3/status` — and
substitute. Do not guess the names.

## Live query, never a cached inventory

`parent-child-hygiene` forbids caching a candidate-parent list in a skill, a
config file or a memory note, and the reasoning applies to every list in this
document: **parents open, close and get renamed constantly; a cached list is
wrong within weeks and is trusted while wrong.**

A staleness note does not fix it. It makes the staleness documented, which is a
different thing — checking a date is a step, and skipping a step is free. The
predictable end state is a gate reading an expired table as authoritative for
months, pointing new work at parents that closed long ago.

**So there is no table of epics in this plugin, deliberately, and there must not
be one.** If the query is too slow or too noisy, fix the query. The failure mode
of a stale table is silent; the failure mode of a bad query is loud.

The same applies to the numeric identifiers the plugin root `SKILL.md` refuses to
ship — issue-type ids, transition ids, `customfield_NNNNN` — for the same reason,
one level down: they are configuration, they drift when an administrator edits a
scheme, and nothing tells you.

## Zero rows is ambiguous

A JQL query that matches nothing and a backlog that contains nothing return the
same thing: an empty `issues` array and a `200`.

Before concluding a sweep is clean, **drop the narrowest clause and confirm the
query returns something.** A misspelled status name, a status that was renamed
last quarter, a project key that is right for a different site, a `~` match on a
word that is stemmed away — every one of these produces a confident empty result.

```bash
# The sweep you meant to run returned nothing. Prove the scope is alive first.
curl -sS -G -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
  --data-urlencode 'jql=project = <PROJECT_KEY>' \
  --data-urlencode 'maxResults=1'
```

Never report a gap as a clean result.

## The triage sweeps

Triage turns captured issues into workable ones. It is read-heavy and
decision-light: each issue gets a type, a status that is true, an assignee or a
stated reason it has none, and a parent or a stated reason it has none.

Run each of these as its own query. The one that finds the most is rarely the
most useful one.

**Untriaged — nothing has been decided about it yet.**

```
project = <PROJECT_KEY> AND statusCategory = "To Do"
  AND assignee IS EMPTY AND labels IS EMPTY
ORDER BY created ASC
```

Oldest first, deliberately: the ones that have been sitting longest are the ones
triage keeps skipping.

**Unassigned work that claims to be started.** The highest-signal sweep in this
list, because every row is a state that is lying:

```
project = <PROJECT_KEY> AND statusCategory = "In Progress" AND assignee IS EMPTY
ORDER BY updated DESC
```

**Stale in-progress — assigned, claimed started, untouched.**

```
project = <PROJECT_KEY> AND statusCategory = "In Progress" AND updated < -14d
ORDER BY updated ASC
```

`status-vocabulary`: *leaving an item in progress for a week while it is blocked
on someone else makes the in-progress list useless for the one purpose it has.*
Each row here is either blocked work that should move back, or finished work that
nobody transitioned. Both need a decision, not a note.

**Closed with no reason recorded.** The Jira-specific defect — a `done`-category
status carrying no resolution, which erases the finished-versus-abandoned
distinction the core insists must survive:

```
project = <PROJECT_KEY> AND statusCategory = Done AND resolution IS EMPTY
ORDER BY resolved DESC
```

**Started and then abandoned** — history clauses earn their cost here:

```
project = <PROJECT_KEY>
  AND status CHANGED TO "<IN_PROGRESS_STATUS>" BEFORE -30d
  AND statusCategory != Done
  AND updated < -30d
ORDER BY updated ASC
```

**Duplicate check before filing.** Run this before creating anything, per the
core's dedupe rule. Search on the symptom, not on the wording you were about to
use in your own summary — the existing issue was filed in different words:

```
project = <PROJECT_KEY> AND statusCategory != Done
  AND text ~ "<SYMPTOM PHRASE>"
ORDER BY updated DESC
```

**Everything attached to one key** — the "why is this code here" question, a year
later:

```
project = <PROJECT_KEY> AND (issuekey = PROJ-123 OR parent = PROJ-123 OR text ~ "PROJ-123")
ORDER BY created ASC
```

## The orphan sweep

`parent-child-hygiene` mandates this periodically and as part of the gate. An
orphan in Jira is an issue that is not itself top-level and has no live parent,
and it has three spellings that are the same defect:

**No parent at all:**

```
project = <PROJECT_KEY> AND statusCategory != Done
  AND issuetype NOT IN (Epic)
  AND parent IS EMPTY
ORDER BY created DESC
```

Substitute your project's own top-level issue type for `Epic` if it differs, and
read it from `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes` rather
than assuming.

**A parent that is no longer live** — the failure mode that survives every "does
it have a parent" check ever written, because the answer is technically yes.
JQL cannot express "my parent's status category", so this is two queries and a
set operation:

```bash
# 1. dead parents
dead=$(curl -sS -G -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
  --data-urlencode 'jql=project = <PROJECT_KEY> AND issuetype = Epic AND statusCategory = Done' \
  --data-urlencode 'fields=summary' --data-urlencode 'maxResults=100' \
  | python3 -c 'import sys,json; print(",".join(i["key"] for i in json.load(sys.stdin).get("issues",[])))')

# 2. live children hanging off them
[ -n "$dead" ] && curl -sS -G -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/search/jql" \
  --data-urlencode "jql=project = <PROJECT_KEY> AND statusCategory != Done AND parent IN ($dead) ORDER BY updated DESC" \
  --data-urlencode 'fields=summary,status,parent'
```

That first query is itself capped at 100. If it returns 100, widen it and say
which number you are quoting — a truncated dead-parent list produces a
false-clean orphan sweep, which is exactly the shape of failure this sweep
exists to catch.

Add the deferred and declined statuses to step 1 alongside `statusCategory =
Done`, for the same reason the liveness filter needs them: neither is ever a
valid parent and neither sits in the `Done` category on every workflow.

**A parent that no longer exists** shows up as an error resolving the key, not as
a JQL result. Treat it identically.

All three are repaired the same way — see `epic-and-parent-hygiene`. Repair when
found. The core is explicit that an orphan noted and left is not a fixed orphan.

## Boards and sprints

Sprint clauses need a board, and board ids are per-site configuration like
everything else. Discover:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/agile/1.0/board?projectKeyOrId=<PROJECT_KEY>"
```

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/agile/1.0/board/<BOARD_ID>/sprint?state=active"
```

Note the different base path: the agile endpoints live under `/rest/agile/1.0/`,
not `/rest/api/3/`. A `404` on a board id is usually this, not a missing board.

**A project may have several boards, or none.** `sprint in openSprints()` in a
project with two boards means "open on any board", which is rarely the question
you meant. Scope by board id when it matters.

## Handoffs

- Reading and writing the issues these queries find: `jira-issue-lifecycle`.
- Deciding what an orphan's repair should be: `epic-and-parent-hygiene`, and
  `parent-child-hygiene` in `issue-tracker-core` for why.
- What a status is claiming: `status-vocabulary`, same plugin.
