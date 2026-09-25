# Jira Cloud REST API v3: the fallback path

Use this when the Atlassian MCP server is not connected and the session has a shell and an API
token (Claude Code). Removed endpoints and fields are listed in `platform-changes.md`.

## Contents

1. Credentials and the auth check
2. Discovering identifiers
3. Reading an issue
4. Reading comments
5. Creating and assigning
6. Transitions, closing and reopening
7. Comments in Atlassian Document Format
8. Parent and issue links
9. Search with JQL
10. Boards and sprints
11. Common failures

Every block below is self-contained. Shell variables do not survive from one Bash call to the
next, so each block reads the three environment variables itself, and `${VAR:?}` stops the
block with a clear message when one is missing. Replace the `<…>` placeholders with values
discovered on this site; never reuse an id from an example.

## 1. Credentials and the auth check

| Variable | Holds |
| --- | --- |
| `JIRA_SITE` | The site host, for example `yourco.atlassian.net` |
| `JIRA_EMAIL` | The Atlassian account's email |
| `JIRA_API_TOKEN` | An API token for that account (Atlassian account settings → Security → API tokens) |

Export them in the shell that launches Claude Code. A token never goes in a skill, a committed
file, a commit message or a comment. A 1Password `op://` reference is resolved only when Claude
Code itself runs under `op run -- claude`; otherwise curl sends the literal `op://…` string and
gets a 401.

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/myself" \
  | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("accountId", "NO ACCOUNT: %s" % d), d.get("displayName", ""))'
```

A 401 or a body without `accountId` means the credential is wrong. Stop and say so; an expired
token and an empty backlog otherwise look the same.

If the team uses Atlassian's `acli`, read `acli --help` for the command rather than translating
an endpoint into a guessed subcommand.

## 2. Discovering identifiers

Issue-type, transition, status, resolution, priority and custom-field ids differ per site, and a
wrong id is often accepted (a Task where you meant a Bug). Read them from the site each time:

| Identifier | Endpoint |
| --- | --- |
| Your own `accountId` | `GET /rest/api/3/myself` |
| Someone else's `accountId` | `GET /rest/api/3/user/assignable/search?project=<PROJECT_KEY>&query=<name or email>` |
| Project key, id and style | `GET /rest/api/3/project/search?query=<text>` |
| Issue types, with `hierarchyLevel` | `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes` |
| Fields for one issue type | `GET /rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes/<ISSUE_TYPE_ID>` |
| Field ids, including `customfield_NNNNN` | `GET /rest/api/3/field` |
| Statuses per issue type, with categories | `GET /rest/api/3/project/<PROJECT_KEY>/statuses` |
| Transitions from an issue's current status | `GET /rest/api/3/issue/<KEY>/transitions` |
| Resolutions | `GET /rest/api/3/resolution` |
| Issue link types | `GET /rest/api/3/issueLinkType` |
| Boards | `GET /rest/agile/1.0/board?projectKeyOrId=<PROJECT_KEY>` |

Any of them in one call:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes" \
  | python3 -m json.tool
```

## 3. Reading an issue

The facts the gate needs, printed as plain lines (works on Python 3.8 and later):

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>?fields=summary,status,resolution,assignee,parent,issuetype" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "fields" not in d:
    sys.exit("No issue returned: %s" % json.dumps(d)[:300])
f = d["fields"]
status = f["status"]
assignee = (f.get("assignee") or {}).get("displayName", "unassigned")
resolution = (f.get("resolution") or {}).get("name", "none")
parent = f.get("parent")
print("[%s] %s (%s)" % (d["key"], f["summary"], f["issuetype"]["name"]))
print("Status: %s | category: %s | resolution: %s" % (status["name"], status["statusCategory"]["key"], resolution))
print("Assignee: %s" % assignee)
if parent:
    ps = parent.get("fields", {}).get("status", {})
    print("Parent: %s | %s | category: %s" % (parent["key"], ps.get("name", "?"), ps.get("statusCategory", {}).get("key", "?")))
else:
    print("Parent: none")
'
```

A 404 means the issue does not exist or this account cannot browse it. Use the output to fill
the `pre-work-gate` summary; the category key is `new`, `indeterminate` or `done`.

## 4. Reading comments

Comments come back as Atlassian Document Format (a JSON tree). This prints them as text, oldest
first, and says whether the page was the whole thread:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/comment?orderBy=created&startAt=0&maxResults=100" \
  | python3 -c '
import json, sys
BLOCKS = {"paragraph", "heading", "listItem", "codeBlock", "blockquote", "rule"}
def text(node):
    kind = node.get("type")
    if kind == "text":
        return node.get("text", "")
    if kind == "hardBreak":
        return "\n"
    inner = "".join(text(child) for child in node.get("content", []))
    return inner + "\n" if kind in BLOCKS else inner
d = json.load(sys.stdin)
comments = d.get("comments", [])
for c in comments:
    print("--- %s, %s" % (c["author"]["displayName"], c["created"]))
    print(text(c["body"]).strip())
shown = d.get("startAt", 0) + len(comments)
print("=== %d of %d comments read%s" % (shown, d.get("total", shown), "" if shown >= d.get("total", shown) else "; fetch the next page with startAt=%d" % shown))
'
```

## 5. Creating and assigning

Run the dedupe search first (`tracker-discipline` § Dedupe before creating). Then create with
the issue-type id from section 2, the parent, and the assignee in one call:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue" --data @- <<'JSON'
{
  "fields": {
    "project":   { "key": "<PROJECT_KEY>" },
    "issuetype": { "id": "<ISSUE_TYPE_ID>" },
    "parent":    { "key": "<PARENT_KEY>" },
    "assignee":  { "accountId": "<ACCOUNT_ID>" },
    "summary":   "Retry transient upstream failures in the ingestion worker",
    "description": {
      "type": "doc", "version": 1,
      "content": [
        { "type": "paragraph", "content": [ { "type": "text", "text": "The worker aborts the batch on the first transient 503." } ] },
        { "type": "paragraph", "content": [ { "type": "text", "text": "Acceptance: transient 5xx responses are retried with bounded backoff." } ] }
      ]
    }
  }
}
JSON
```

The response carries the new `key`. A 400 naming a `customfield_NNNNN` means the project's
create screen requires that field; look it up in the per-type createmeta call and add it. A new
issue lands in the workflow's initial status, whatever that is; read it back (section 3).

Assign an existing issue (the id comes from section 2, never from memory):

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X PUT -H "Content-Type: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/assignee" \
  --data '{"accountId": "<ACCOUNT_ID>"}'
```

## 6. Transitions, closing and reopening

List the transitions available from the issue's current status, with any screen fields:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/transitions?expand=transitions.fields" \
  | python3 -c '
import json, sys
for t in json.load(sys.stdin).get("transitions", []):
    required = [k for k, v in t.get("fields", {}).items() if v.get("required")]
    print("%s -> %s | category: %s | required fields: %s" % (t["id"], t["to"]["name"], t["to"]["statusCategory"]["key"], ", ".join(required) or "none"))
'
```

Run one by id. A success is `HTTP 204` with no body, so read the issue back afterwards
(section 3):

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X POST -H "Content-Type: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/transitions" \
  --data '{"transition": {"id": "<TRANSITION_ID>"}}'
```

Close with the resolution in the same call, so the issue is never closed without a reason
(resolution names come from `GET /rest/api/3/resolution`):

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X POST -H "Content-Type: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/transitions" \
  --data '{"transition": {"id": "<TRANSITION_ID>"}, "fields": {"resolution": {"name": "<RESOLUTION_NAME>"}}}'
```

Reopen by sending `"fields": {"resolution": null}` with the transition back. Whether the
transition screen accepts that, or the workflow clears it for you, varies; if the read-back
still shows a resolution, clear it with
`PUT /rest/api/3/issue/<KEY>` and body `{"fields": {"resolution": null}}`, and say so in a comment.

## 7. Comments in Atlassian Document Format

v3 takes a comment body as ADF: one `paragraph` node per paragraph, text in `text` nodes. Build
it in Python so quotes, backticks and `$` in the prose never meet shell quoting, and send it only
if it built:

```bash
(
set -euo pipefail
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
python3 - > "$payload" <<'PY'
import json
paragraphs = [
    "Starting on fix/PROJ-123-retry-ingestion-worker. Plan: wrap the upstream client in a bounded retry with backoff.",
    "Differs from the description: the worker does not yet tell transient from permanent failures, so this adds that first.",
]
body = {"type": "doc", "version": 1, "content": [
    {"type": "paragraph", "content": [{"type": "text", "text": p}]} for p in paragraphs
]}
print(json.dumps({"body": body}))
PY
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>/comment" --data @"$payload"
)
```

`HTTP 201` means it posted. Put the three `tracker-discipline` templates (start, handoff,
finish) into `paragraphs`, one line of the template per paragraph. Read the latest comment
back with `…/comment?orderBy=-created&maxResults=1`.

## 8. Parent and issue links

`parent` is the only hierarchy field (see `platform-changes.md`). Set or change it:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X PUT -H "Content-Type: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issue/<KEY>" \
  --data '{"fields": {"parent": {"key": "<PARENT_KEY>"}}}'
```

`HTTP 204` confirms nothing about the result; read the issue back (section 3) and check the
parent's category is not `done`.

An issue link (blocks, relates to, duplicates) is a peer relationship and never a parent.
Link type names come from `GET /rest/api/3/issueLinkType`:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -w '\nHTTP %{http_code}\n' \
  -X POST -H "Content-Type: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/issueLink" \
  --data '{"type": {"name": "Blocks"}, "inwardIssue": {"key": "<BLOCKING_KEY>"}, "outwardIssue": {"key": "<BLOCKED_KEY>"}}'
```

## 9. Search with JQL

`GET /rest/api/3/search/jql` with `curl -G --data-urlencode`, so `!=`, quotes and `~` are
encoded correctly; a mis-encoded query does not fail, it returns a different result set. Name
the `fields`, because the endpoint returns only ids without them.

This loop reads every page, prints one line per issue, and ends with a line saying whether the
sweep is complete. Set the JQL and fields on the two marked lines:

```bash
(
set -euo pipefail
jql='project = <PROJECT_KEY> AND statusCategory != Done ORDER BY updated DESC'   # the query
fields='summary,status,assignee,parent,updated'                                     # the fields
token=""; pages=0; rows=0; max_pages=20
while :; do
  args=(--data-urlencode "jql=$jql" --data-urlencode "fields=$fields" --data-urlencode "maxResults=100")
  if [ -n "$token" ]; then args+=(--data-urlencode "nextPageToken=$token"); fi
  resp=$(curl -sS -G -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
    "https://${JIRA_SITE:?}/rest/api/3/search/jql" "${args[@]}")
  out=$(printf '%s' "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if "issues" not in d:
    sys.exit("Search failed: %s" % json.dumps(d)[:300])
for i in d["issues"]:
    f = i.get("fields", {})
    status = f.get("status", {})
    parent = (f.get("parent") or {})
    pstatus = parent.get("fields", {}).get("status", {})
    print("ROW\t%s\t%s\t%s\t%s\tparent=%s(%s)" % (i["key"], status.get("name", ""), status.get("statusCategory", {}).get("key", ""),
        f.get("summary", ""), parent.get("key", "none"), pstatus.get("statusCategory", {}).get("key", "")))
print("TOKEN\t%s" % (d.get("nextPageToken") or ""))
')
  printf '%s\n' "$out" | grep '^ROW' | cut -f2- || true
  rows=$((rows + $(printf '%s\n' "$out" | grep -c '^ROW' || true)))
  token=$(printf '%s\n' "$out" | grep '^TOKEN' | cut -f2)
  pages=$((pages + 1))
  if [ -z "$token" ]; then echo "=== complete: $rows issues in $pages page(s)"; break; fi
  if [ "$pages" -ge "$max_pages" ]; then echo "=== INCOMPLETE: stopped after $pages pages and $rows issues"; break; fi
done
)
```

Quote the last line with any count you report. For an estimate without paging:

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" \
  -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/api/3/search/approximate-count" \
  --data '{"jql": "project = <PROJECT_KEY> AND statusCategory != Done"}'
```

## 10. Boards and sprints

Board and sprint endpoints live under `/rest/agile/1.0/`, not `/rest/api/3/`; a 404 on a board
id is usually the wrong base path.

```bash
curl -sS -u "${JIRA_EMAIL:?}:${JIRA_API_TOKEN:?}" -H "Accept: application/json" \
  "https://${JIRA_SITE:?}/rest/agile/1.0/board?projectKeyOrId=<PROJECT_KEY>"
```

Active sprints on one board: `GET /rest/agile/1.0/board/<BOARD_ID>/sprint?state=active`.

## 11. Common failures

| Symptom | Cause | Repair |
| --- | --- | --- |
| `parameter null or not set` from the shell | A variable is missing from Claude Code's environment | Export it and restart Claude Code; section 1 |
| 401 | Wrong email or token, or an unresolved `op://` reference | Run the auth check in section 1 |
| 404 on an issue visible in the browser | Wrong `JIRA_SITE`, or the account lacks Browse Projects | Check the host; check the account with `/myself` |
| 410 naming CHANGE-2046 | A call to the removed `/rest/api/3/search` | Use `/rest/api/3/search/jql` (section 9) |
| 400 naming `customfield_NNNNN` on create | A required field is missing | Section 2, fields for one issue type |
| 400 on a transition, naming fields | The transition has a screen | List with `expand=transitions.fields` and send them |
| `HTTP 204` but the issue did not move | The transition id came from another status or workflow | List transitions again from the issue in hand |
| A comment renders as one run-on block | Several paragraphs in one text node | One `paragraph` node per paragraph (section 7) |
| Search returns issues with no fields | `fields` not named | Add `fields=` (section 9) |
