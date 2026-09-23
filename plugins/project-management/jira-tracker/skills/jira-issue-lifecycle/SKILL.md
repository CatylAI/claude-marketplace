---
name: jira-issue-lifecycle
description: "Carry out the pre-work gate and the issue comment trail against Jira Cloud with the REST API v3 — find or create a scoped assigned issue before writing code, read its full state including the comment thread, derive the branch name and change title from the key, post the start, handoff and finish comments in Atlassian Document Format, discover and run transitions, and close honestly. Use at the start of any implementation task in a Jira-tracked repository, when opening a change for review, when pausing mid-stream, and when work merges."
license: MIT
---

# Issue Lifecycle on Jira

`pre-work-gate` and `issue-lifecycle` in `issue-tracker-core` say what must be
true and what must be recorded. This skill is how that happens against Jira
Cloud.

Every call below is literal except for the placeholders. Substitute `<SITE>`,
`<PROJECT_KEY>` and `<KEY>`; change nothing else. Credentials come from
`JIRA_EMAIL` and `JIRA_API_TOKEN` per the plugin root `SKILL.md`, and appear in
no file.

For readability, each example writes the auth out in full. In a real session,
set it once:

```bash
JIRA_BASE="https://<SITE>.atlassian.net"
JIRA_AUTH=(-u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json")
```

## Step 1 — Find the key

Branch first, per the core's search order:

```bash
git branch --show-current
```

Match the result against the configured `CLAUDE_TICKET_PATTERN`. Jira keys match
the core's default unchanged — see the plugin root `SKILL.md` for why this is the
one tracker where nothing has to be configured:

```bash
git branch --show-current | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1
```

That prints the key. No match means no key on the branch; fall through to the
user's message, then to earlier session context, then ask. Do not invent one and
do not attach to the nearest plausible issue.

If the repository touches more than one Jira project, or a branch name contains
something else key-shaped, narrow the expression to your own project key rather
than taking the first match on trust.

## Step 2 — Fetch the issue, do not trust the key

A key proves someone typed a string. Read the issue:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>?fields=summary,status,assignee,issuetype,parent,labels,priority,resolution,created,updated"
```

A `404` means the issue does not exist or you cannot see it. Stop and ask; do
not create one to make the gate pass.

Render the one-line summary the core requires before doing anything else:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>?fields=summary,status,assignee" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); f=d["fields"]; a=f.get("assignee") or {}; print(f"[{d[\"key\"]}] {f[\"summary\"]} — Status: {f[\"status\"][\"name\"]} — Assignee: {a.get(\"displayName\",\"unassigned\")}")'
```

Two fields on that response are load-bearing and easy to skim past:

- `fields.status.statusCategory.key` is one of `new`, `indeterminate` or `done`.
  That is the *category*, and it is what liveness checks must filter on — see
  `jira-jql`. `fields.status.name` is the project's own label for the status and
  is configurable per workflow.
- `fields.resolution` is `null` on an unresolved issue. An issue can sit in a
  status whose name sounds terminal while carrying no resolution; the two are
  separate fields and they disagree more often than teams expect.

## Step 3 — Read the full state, including comments

The gate's scope check needs the comment thread, not just the description. A
scope negotiation from three weeks ago lives there.

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/comment?orderBy=created&maxResults=50"
```

The comment list is paginated: the response carries `startAt`, `maxResults` and
`total`. **If `total` exceeds what you fetched, you read a prefix of the thread
and the scope negotiation may be in the part you skipped.** Page with `startAt`
rather than concluding from the first page.

Descriptions and comment bodies come back as Atlassian Document Format — a JSON
tree, not a string. To read the prose rather than the tree, either walk the
`content` array, or request the v2 representation, which renders the same field
as a plain string:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/2/issue/<KEY>?fields=summary,description"
```

**Flagged:** `/rest/api/2/` remains available on Jira Cloud and is the pragmatic
way to read and write text without building ADF. Its long-term status relative to
v3 has been signalled more than once, so treat it as a convenience rather than a
foundation: read with v2 if you like, but keep writes on v3 with real ADF so a
deprecation does not silently change what your comments look like.

## Step 4 — Satisfy the gate

Four properties, four repairs.

**Exists** — Step 2 returned `200`.

**Assigned** — if `fields.assignee` is `null`, or is not whoever is doing the
work. Assignment is its own endpoint and takes an `accountId`, never a username
or an email:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X PUT -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/assignee" \
  --data '{"accountId": "<ACCOUNT_ID>"}'
```

Get your own `accountId` from `GET /rest/api/3/myself`. Get someone else's from
the assignable-user search, which is scoped to people who can actually hold the
issue:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/user/assignable/search?project=<PROJECT_KEY>&query=<NAME_OR_EMAIL>"
```

**Never hardcode an `accountId`.** It is per-person and per-site, it is not
guessable, and a wrong one either fails or silently assigns work to a stranger.

**Workable state** — transition it, per Step 5. Do this before the first edit to
a source file, not at the end of the session.

**Parented** — see `epic-and-parent-hygiene`. Checking that `fields.parent`
exists is not enough; a parent in a terminal state reads as compliant and is not.

### When no suitable issue exists

Create one. A created issue is scoped, assigned and parented in the same call,
because a follow-up step is the step that does not happen.

First discover what this project accepts — you cannot write a create call without
the issue-type IDs, and they differ per site:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes"
```

Then create, substituting the `id` you just read:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue" \
  --data @- <<'JSON'
{
  "fields": {
    "project":   { "key": "<PROJECT_KEY>" },
    "issuetype": { "id": "<ISSUE_TYPE_ID>" },
    "assignee":  { "accountId": "<ACCOUNT_ID>" },
    "parent":    { "key": "<EPIC_KEY>" },
    "summary":   "Retry transient upstream failures in the ingestion worker",
    "description": {
      "type": "doc",
      "version": 1,
      "content": [
        { "type": "heading", "attrs": { "level": 2 },
          "content": [ { "type": "text", "text": "Problem" } ] },
        { "type": "paragraph",
          "content": [ { "type": "text", "text": "The ingestion worker aborts the batch on the first transient upstream 503." } ] },
        { "type": "heading", "attrs": { "level": 2 },
          "content": [ { "type": "text", "text": "Acceptance" } ] },
        { "type": "bulletList", "content": [
          { "type": "listItem", "content": [ { "type": "paragraph", "content": [
            { "type": "text", "text": "Transient 5xx responses are retried with backoff, bounded at 5 attempts." } ] } ] },
          { "type": "listItem", "content": [ { "type": "paragraph", "content": [
            { "type": "text", "text": "A permanently failing record is quarantined, not retried forever." } ] } ] }
        ] }
      ]
    }
  }
}
JSON
```

The response carries `{"id": ..., "key": "<KEY>", "self": ...}`. Keep the `key`.

Three things that go wrong here every time:

- **`issuetype` by `id`, not by `name`.** Names are editable and duplicated
  across projects; the id is stable within the site. You read it from createmeta
  one step earlier, so there is no reason to guess.
- **A field that is required by the project's screen but absent from your body
  returns `400` naming the field id**, often as `customfield_NNNNN` with no hint
  what it is. Resolve it against
  `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes/<ISSUE_TYPE_ID>`,
  which lists the fields for that type, and against `GET /rest/api/3/field` for
  the human name.
- **A new issue lands in the project's configured initial status**, whatever that
  is. It is not necessarily the one you want, and it is not "backlog" because you
  expected backlog. Read the status back.

Creating a new issue does not exempt you from the scope check — it *is* the scope
check's remedy. If the user asked for one thing and an existing issue covers a
different thing, the correct output is a new issue plus a sentence saying which
issue the work now attaches to.

## Step 5 — Transitions, which are per-workflow and must be discovered

Jira has no fixed set of states. A project's workflow defines its statuses, and a
*transition* is an edge between them with its own numeric id. **Those ids are
configuration, not content: they differ per workflow, and an administrator
editing the workflow changes them without telling anyone.**

So discover, every time, from the issue in hand:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/transitions" \
  | python3 -c 'import sys,json; [print(t["id"], "->", t["to"]["name"], "|", t["to"]["statusCategory"]["key"]) for t in json.load(sys.stdin)["transitions"]]'
```

That endpoint returns **only the transitions available from the issue's current
status**, which is itself the useful signal: an empty list, or a list missing the
edge you expected, means the workflow does not allow the move you were about to
make, not that the API failed.

Then execute by id:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/transitions" \
  --data '{"transition": {"id": "<TRANSITION_ID>"}}'
```

A successful transition returns `204 No Content` — **no body, which means no
confirmation of where the issue landed.** The core requires reading back anything
automation claimed to do, and this is the clearest case for it:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>?fields=status,resolution" \
  | python3 -c 'import sys,json; f=json.load(sys.stdin)["fields"]; r=f.get("resolution") or {}; print(f["status"]["name"], "|", f["status"]["statusCategory"]["key"], "| resolution:", r.get("name","none"))'
```

Notes that save a debugging session:

- **A transition screen can require fields.** If the workflow puts a screen on
  the transition, the `POST` must carry them in a `fields` object alongside
  `transition`, and it `400`s naming them otherwise. `GET .../transitions?expand=transitions.fields`
  tells you in advance which transitions have one.
- **Assignee is commonly not on the transition screen.** Where it is not, a
  combined transition-plus-assign call fails. Transition first, then assign (or
  the reverse) — two calls, not one.
- **Cancelling counts as a transition too.** There is no separate "close"
  endpoint; abandoning an issue is a move to a terminal status like any other.

## Step 6 — Mapping the core's vocabulary onto this project's workflow

`status-vocabulary` defines seven states and forbids inventing an eighth. Jira
defines whatever the project's workflow says. The mapping belongs here, in the
adapter, and belongs written down per project rather than assumed:

| Core state | What to map it to | How to find the local name |
| --- | --- | --- |
| Backlog | The project's initial status | Create a scratch issue and read its status back, or read the workflow |
| Ready | A prioritised-not-started status | `GET /rest/api/3/status` for the project's set |
| In progress | The status whose category is `indeterminate` and which the team means by "started" | Category alone is ambiguous; ask the team |
| In review | A distinct status, if one exists | Many workflows have none — see below |
| Done | A `done`-category status with a completion resolution | `GET /rest/api/3/resolution` |
| Parked | A `new`- or `indeterminate`-category deferral status | Often absent; see below |
| Declined | A `done`-category status with a not-doing resolution | The *resolution* is what distinguishes it from Done |

Two mappings that routinely fail, and what to do rather than pretend:

- **No review status.** Where the workflow has none, "in review" is carried by
  the linked change plus a comment, and the issue stays in progress. Say that in
  the repository's own docs. Do not add a status — that is a workflow edit, it is
  an admin action, and `status-vocabulary` rule 2 forbids inventing one locally.
- **No parked status.** Where the workflow has none, parked is an unresolved
  issue with a comment naming the revisit condition. **Do not transition it to a
  `done`-category status to get it off the board.** The core is explicit that
  collapsing finished and abandoned destroys the only signal that tells you
  whether the backlog is shrinking because work is landing or because work is
  being dropped — and in Jira that collapse is especially invisible, because a
  `done` category looks identical in every rollup regardless of resolution.

**The resolution field is where finished and abandoned actually live.** Two
issues can share one `done`-category status and differ entirely in `resolution`.
Set it deliberately on the closing transition; a `null` resolution on a closed
issue is the Jira spelling of "closed with no reason recorded".

## Step 7 — Branch, title, scope

The core's rule: the key must be recoverable from the branch name.

```bash
git switch -c fix/PROJ-123-retry-ingestion-worker
```

Everything downstream is then mechanical:

| Artefact | Value | Derived how |
| --- | --- | --- |
| Commit scope | `PROJ-123` | The pattern match on the branch |
| Change title | `fix(PROJ-123): retry transient upstream failures` | Type from the branch prefix, scope from the key |
| Tracker comment | Links the change to `PROJ-123` | Posted by Step 8 |
| Later search | `git log --grep PROJ-123`, plus one JQL on the key | One token, two systems |

The prefix-to-type mapping is the core's: `feature` → `feat`, `fix` → `fix`,
`refactor` → `refactor`, `chore` → `chore`, `docs` → `docs`.

Recover the whole set from a branch in one go:

```bash
branch=$(git branch --show-current)
key=$(grep -oE '[A-Z][A-Z0-9]+-[0-9]+' <<< "$branch" | head -1)
type=${branch%%/*}
echo "key=$key branch-prefix=$type"
```

If `key` comes back empty, the branch predates the convention. Per the core: ask
for the key, then fix the change title rather than renaming a branch someone else
may have checked out.

**Jira does not close an issue from a commit message on its own.** Unlike forges
with closing keywords, mentioning the key in a commit or a merge request links
the two (where the development integration is installed) but does not transition
anything. The transition is a call you make — Step 5 — or an automation rule the
project has configured. Find out which, once, and write it down; assuming the
automation exists is how an issue sits in progress a week after its change
merged.

## Step 8 — The comment trail

Three comments are mandatory. In v3 a comment body is ADF, so the simple case
looks like this:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/comment" \
  --data @- <<'JSON'
{
  "body": {
    "type": "doc",
    "version": 1,
    "content": [
      { "type": "paragraph", "content": [
        { "type": "text", "text": "Starting on fix/PROJ-123-retry-ingestion-worker. Plan: wrap the existing upstream client in a bounded retry with exponential backoff, so no call site changes. The description assumes the worker already distinguishes transient from permanent failures — it does not, so this adds that classification first." }
      ] }
    ]
  }
}
JSON
```

Building that by hand for a multi-paragraph comment is miserable and error-prone.
Build it in Python instead, so prose containing quotes, backticks and `$` never
has to survive shell quoting:

```bash
python3 - <<'PY' > /tmp/jira-comment.json
import json
paras = [
    "Pausing here. Retry wrapper is written and unit-tested. The integration "
    "test against the staging queue fails on expired fixtures, which is "
    "unrelated to this change.",
    "Next step: refresh the queue fixtures, then open the change for review.",
]
body = {"type": "doc", "version": 1, "content": [
    {"type": "paragraph", "content": [{"type": "text", "text": p}]} for p in paras
]}
print(json.dumps({"body": body}))
PY

curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/comment" \
  --data @/tmp/jira-comment.json
```

**Validate the file before sending it.** A generator that raised half way through
leaves a truncated or empty file, and `--data @file` will send it — producing a
`400` that reads like an API problem rather than a build problem:

```bash
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' /tmp/jira-comment.json \
  || { echo "STOP: comment payload not built — not sending"; exit 1; }
```

The three moments, per `issue-lifecycle`:

| Moment | The comment contains | Paired with |
| --- | --- | --- |
| **Start** | The approach, anything the description got wrong, the branch name | Transition to the in-progress status |
| **Handoff / pause** | Where things stand, what is known-broken, the single next step | Transition out of in-progress, or an explicit statement that it stays there and why |
| **Finish** | The link to the merged change and confirmation that acceptance is met | Transition to the terminal status, with a resolution |

What does not get a comment: "still working on this". The core is explicit that
routine progress noise trains readers to skim the thread, which is how a real
comment gets missed.

### Verify the comment landed

`POST .../comment` returns `201` with the created comment, so success is visible
— but when the post went through a wrapper, a hook or an agent, read it back:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/comment?orderBy=-created&maxResults=1"
```

### Visibility restrictions

A comment can be restricted to a role or group with a `visibility` object. Use it
only where the content genuinely requires it, and remember what it costs: **a
restricted comment is invisible to readers outside that role, so a thread that
reads as complete to you may be missing its decisive comment for everyone else.**
The core's whole claim is that the issue is the durable record; a record only
some readers can see is a weaker one.

## Step 9 — Closing, and reopening

Closing is a transition to a terminal status *plus* a resolution, in the same
call, so there is no window in which the issue is closed with no reason:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/transitions" \
  --data '{
    "transition": { "id": "<TRANSITION_ID>" },
    "fields":     { "resolution": { "name": "<RESOLUTION_NAME>" } }
  }'
```

Resolution names are per-site — read them from `GET /rest/api/3/resolution` and
use the one your team means by *finished* versus the one it means by *not
doing*. That distinction is the one `status-vocabulary` says must survive any
mapping, and in Jira the resolution field is the only place it lives.

Reopening is a transition back, and it must also retract the resolution — an
issue that is open again while still carrying a completion resolution asserts two
contradictory things at once:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>/transitions" \
  --data '{
    "transition": { "id": "<TRANSITION_ID>" },
    "fields":     { "resolution": null }
  }'
```

**Flagged as instance-dependent:** whether `resolution: null` is accepted on a
transition, and whether the workflow clears it for you, depends on the transition's
post-functions and screens. Read the issue back and confirm `fields.resolution`
is `null`; if it is not, clear it with a separate `PUT /rest/api/3/issue/<KEY>`
edit, and say in the comment that you did.

Reopening does not re-derive a branch. If the original branch merged and was
deleted, cut a new one against the same key. Two branches, one key, one history:
that is the convention working, not a violation of it.

## Common failures

| Symptom | Cause | Repair |
| --- | --- | --- |
| `404` on an issue you can see in the browser | Wrong site host, or the token's account lacks Browse Projects on that project | Re-check `<SITE>`; confirm the account with `GET /rest/api/3/myself` |
| `400` naming `customfield_NNNNN` on create | A field required by the project's create screen is missing | Resolve the id with `GET /rest/api/3/field`; read the required set from createmeta |
| `400` on transition, naming fields | The transition has a screen | Re-request transitions with `expand=transitions.fields` and send them |
| Transition returns `204`, issue did not move | The id came from a cached list taken at a different status, or from another project's workflow | Re-discover transitions from the issue in hand, every time |
| Comment posts but renders as one run-on block | ADF built as a single text node with newlines in it | One `paragraph` node per paragraph; ADF ignores `\n` inside a text node |
| Closed issue shows no reason anywhere | Transition ran without a `resolution` | Reopen, then close again with the resolution set |
| Gate finds a key that belongs to another project | `CLAUDE_TICKET_PATTERN` left at the permissive default in a multi-project repo | Tighten it to `<PROJECT_KEY>-[0-9]+` per repository |

## Handoffs

- Writing any query, including the sweeps this gate depends on: `jira-jql`.
- Parents, epics and the orphan sweep: `epic-and-parent-hygiene`.
- What a state is claiming and when it may advance: `status-vocabulary` in
  `issue-tracker-core`.
- Branch and title derivation in the general case:
  `branch-and-title-conventions`, same plugin.
