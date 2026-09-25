# Sub-issues, dependencies and milestones over REST

The fallback for a `gh` release without `--parent`, `--add-sub-issue` or `--add-blocked-by` (see
`issue-lifecycle-github`'s `references/gh-versions.md`), and the id rules the MCP `sub_issue_write`
tool shares. Endpoints were checked against the `github/rest-api-description` OpenAPI file.

## Contents

- [The three ids](#the-three-ids)
- [Endpoints](#endpoints)
- [Attach, re-parent, detach](#attach-re-parent-detach)
- [Read children and parents](#read-children-and-parents)
- [Blocked-by dependencies](#blocked-by-dependencies)
- [Milestones](#milestones)
- [Task lists](#task-lists)

## The three ids

The path takes the issue number. The request body of the sub-issue and dependency endpoints takes
the child's REST database id, which appears nowhere in the UI. The `id` from `gh issue view --json
id` is a third thing, the GraphQL node id.

| What | Where it comes from | Looks like | Used by |
|---|---|---|---|
| Issue number | `#124` in the UI | `124` | Paths, `gh issue` commands, closing keywords |
| REST database id | `gh api repos/{owner}/{repo}/issues/124 --jq .id` | `2184773901` | `sub_issue_id`, `issue_id` bodies; MCP `sub_issue_write` |
| GraphQL node id | `gh issue view 124 --json id --jq .id` | `I_kwDOAbCdEf4AbCdEf` | Projects v2 `contentId` |

Passing a node id or an issue number as `sub_issue_id` fails or targets the wrong issue.

## Endpoints

| Operation | Endpoint |
|---|---|
| List a parent's children | `GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues` (30 per page by default) |
| Add a child | `POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues` with `sub_issue_id`, optional `replace_parent` |
| Remove a child | `DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue` (singular) with `sub_issue_id` |
| Get a child's parent | `GET /repos/{owner}/{repo}/issues/{issue_number}/parent` |
| List blockers | `GET /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocked_by` |
| Add a blocker | `POST …/dependencies/blocked_by` with `issue_id` |
| Remove a blocker | `DELETE …/dependencies/blocked_by/{issue_id}` |

The issue object itself carries `parent_issue_url` (null when there is no parent),
`sub_issues_summary` (`total`, `completed`, `percent_completed`) and `issue_dependencies_summary`.

## Attach, re-parent, detach

Look up the database id and use it in the same Bash call, since variables do not carry over:

```bash
gh api --method POST repos/{owner}/{repo}/issues/40/sub_issues \
  -F sub_issue_id="$(gh api repos/{owner}/{repo}/issues/124 --jq .id)"
```

`-F` sends the id as a JSON number; `-f` would send a string, which the endpoint rejects.

Re-parent in one call: a child already under another parent is moved when `replace_parent` is set.

```bash
gh api --method POST repos/{owner}/{repo}/issues/41/sub_issues \
  -F sub_issue_id="$(gh api repos/{owner}/{repo}/issues/124 --jq .id)" -F replace_parent=true
```

Detach:

```bash
gh api --method DELETE repos/{owner}/{repo}/issues/40/sub_issue \
  -F sub_issue_id="$(gh api repos/{owner}/{repo}/issues/124 --jq .id)"
```

The child must belong to the same repository owner as the parent. Read back with the parent check
below.

With the MCP tools: `issue_read` (`method: get`) returns the child's `id`; pass it to
`sub_issue_write` with `method: add` and `replace_parent: true` to move it.

## Read children and parents

Always paginate a child list. Without `--paginate` the endpoint returns 30 children, and a parent
can hold 100, so a sweep would report the rest as orphans:

```bash
gh api --paginate repos/{owner}/{repo}/issues/40/sub_issues --jq '.[] | "#\(.number)\t\(.state)\t\(.title)"'
```

A child's parent, with its state (a 404 means no parent, or no such issue):

```bash
gh api repos/{owner}/{repo}/issues/124/parent --jq '{number, state, state_reason, title}'
```

## Blocked-by dependencies

```bash
gh api --method POST repos/{owner}/{repo}/issues/123/dependencies/blocked_by \
  -F issue_id="$(gh api repos/{owner}/{repo}/issues/118 --jq .id)"
gh api --paginate repos/{owner}/{repo}/issues/123/dependencies/blocked_by --jq '.[] | "#\(.number)\t\(.state)"'
```

Remove a blocker by its database id: `gh api --method DELETE
repos/{owner}/{repo}/issues/123/dependencies/blocked_by/2184773901`.

## Milestones

`gh` has no milestone subcommand. A `gh api` call with `-f` fields is a POST unless `--method GET`
is passed, so the list needs it:

```bash
gh api --method GET --paginate repos/{owner}/{repo}/milestones \
  -f state=open -f sort=due_on -f direction=asc \
  --jq '.[] | "\(.number)\t\(.title)\tdue \(.due_on // "none" | .[0:10])\topen \(.open_issues)\tclosed \(.closed_issues)"'
```

Create one (a POST on purpose):

```bash
gh api repos/{owner}/{repo}/milestones -f title="<title>" -f description="<scope>" -f due_on="<YYYY-MM-DD>T23:59:59Z"
```

Progress for one milestone:

```bash
gh api repos/{owner}/{repo}/milestones/3 --jq '{title, state, due_on, open: .open_issues, closed: .closed_issues}'
```

The counts include pull requests, because the REST API treats a pull request as an issue.

Clear an issue's milestone when `gh issue edit --remove-milestone` is unavailable:

```bash
echo '{"milestone": null}' | gh api --method PATCH repos/{owner}/{repo}/issues/123 --input -
```

`-f milestone=null` sends the string `"null"`; `--input` sends a real JSON null.

## Task lists

Checkbox references in a parent's body (`- [ ] #124`) predate sub-issues. The tick and the issue
state drift apart, there is no API short of rewriting the body, and nothing stops a child appearing
under two parents. Use them for checklists whose items are not issues, and treat a sub-issue link as
authoritative where both exist.
