---
name: milestones-and-sub-issues
description: "Enforce parent-child hygiene on GitHub — create and read milestones with gh api, assign them with gh issue edit, link a child to a parent with the sub-issues REST endpoints (which key off the numeric database id, not the issue number), choose between sub-issues and body task lists, sweep live for orphans with no milestone and no parent, and audit parents whose children have all closed. Use when creating a GitHub issue, when an issue has no parent, or when auditing a backlog."
license: MIT
---

# Milestones and Sub-Issues

`parent-child-hygiene` states three rules: every non-top-level item has a parent,
the candidate-parent list is a query rather than a table, and an orphan is a
defect to be fixed when found. GitHub gives you two containers to satisfy them
with, and they are not interchangeable.

| Container | Holds | Cardinality | Good for |
| --- | --- | --- | --- |
| **Milestone** | Issues and pull requests | One milestone per issue | A release, an iteration, a time-boxed bucket. The core's stage-1 shortlist. |
| **Sub-issue** | Issues | One parent per child | A genuine decomposition: this issue is part of that issue. |

They compose. An issue can sit in milestone `2026.Q1` and be a sub-issue of
`#40 Ingestion reliability`. The milestone answers "when", the parent answers
"part of what". The core's parent requirement is satisfied by either, but a
repository should decide which one it means, because a sweep that accepts either
finds fewer orphans than one that requires the right one.

## Milestones

### Create

Milestones have no `gh` subcommand. Use the REST API through `gh api`. Supplying
any `-f` flag makes the request a POST:

```
gh api repos/{owner}/{repo}/milestones \
  -f title="2026.Q1" \
  -f state="open" \
  -f description="Ingestion reliability and the retry work that depends on it." \
  -f due_on="2026-03-31T23:59:59Z"
```

`due_on` is an ISO 8601 timestamp in UTC. GitHub stores it to the day; a time
component is accepted and largely ignored in the UI.

The response includes the milestone's `number`, which is what the REST API takes
when assigning. `gh issue edit` takes the title instead.

### List — this is the stage-1 query, run every time

The core forbids caching a candidate-parent list, and milestones are exactly the
thing people cache. Run it:

```
gh api repos/{owner}/{repo}/milestones --paginate \
  -f state=open -f sort=due_on -f direction=asc \
  --jq '.[] | "#\(.number)\t\(.title)\tdue \(.due_on[0:10] // "none")\topen \(.open_issues)\tclosed \(.closed_issues)"'
```

`-f state=open` on a GET is a query parameter, and it is the liveness filter the
core insists on. Without it you get closed milestones back and can cheerfully
file new work under a shipped release.

That output is the shortlist to present. If it runs past ten entries, the
repository has too many open milestones for one of them to be a real choice —
narrow by due date rather than dumping the list.

### Read progress

```
gh api repos/{owner}/{repo}/milestones/3 \
  --jq '{title, state, due_on, open: .open_issues, closed: .closed_issues, percent: ((.closed_issues * 100) / ((.open_issues + .closed_issues) | if . == 0 then 1 else . end) | floor)}'
```

`open_issues` and `closed_issues` count pull requests as well as issues, because
a pull request is an issue to the REST API. A milestone that looks further along
than the work suggests is usually counting merged pull requests.

### Assign and unassign

```
gh issue edit 123 --milestone "2026.Q1"
```

`gh` matches the milestone by title and fails if no open milestone has that
title. Assigning to a closed milestone requires the REST form.

Removing one:

```
gh issue edit 123 --remove-milestone
```

`--remove-milestone` exists in current `gh` releases; if your version rejects it,
the REST form always works and is worth preferring in a script:

```
echo '{"milestone": null}' | gh api --method PATCH repos/{owner}/{repo}/issues/123 --input -
```

Do not try `-f milestone=null` — `-f` sends the literal string `"null"`, which is
not the same thing and will be rejected or misinterpreted.

### List a milestone's contents

```
gh issue list --state all --milestone "2026.Q1" --limit 200 --json number,title,state,labels \
  --jq '.[] | "#\(.number)\t\(.state)\t\(.title)"'
```

## Sub-issues

GitHub's native parent-child link. Three REST endpoints:

| Operation | Endpoint |
| --- | --- |
| List a parent's children | `GET /repos/{owner}/{repo}/issues/{issue_number}/sub_issues` |
| Add a child | `POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues` |
| Remove a child | `DELETE /repos/{owner}/{repo}/issues/{issue_number}/sub_issue` |

Note the singular `sub_issue` on the DELETE. That is not a typo in this document;
it is an inconsistency in the API, and it is the second most common mistake here.

### The id trap — read this before writing any sub-issue call

The `{issue_number}` in the **path** is the issue number you see in the UI, the
one written `#123`.

The **body** does not take a number. It takes `sub_issue_id`, which is the
child's numeric **database id** — a seven- or eight-digit integer that appears
nowhere in the UI and is unrelated to the issue number.

And the `id` returned by `gh issue view <n> --json id` is neither. That is the
**GraphQL node id**, an opaque string like `I_kwDOAbCdEf4AbCdEf`. Passing it to
`sub_issue_id` fails; passing an issue number there either fails or, worse,
silently attaches whichever unrelated issue happens to own that database id.

Get the REST id from the REST API:

```
gh api repos/{owner}/{repo}/issues/124 --jq .id
```

Three ids for one issue, and only one of them is right here:

| What you want | Where it comes from | Looks like |
| --- | --- | --- |
| Issue number — path segment, `#` references | `gh issue view 124 --json number --jq .number` | `124` |
| REST database id — `sub_issue_id` | `gh api repos/{owner}/{repo}/issues/124 --jq .id` | `2184773901` |
| GraphQL node id — Projects v2 `contentId` | `gh issue view 124 --json id --jq .id` | `I_kwDOAbCdEf4AbCdEf` |

### Add a child

```
child_id=$(gh api repos/{owner}/{repo}/issues/124 --jq .id)
gh api --method POST repos/{owner}/{repo}/issues/40/sub_issues -F sub_issue_id="$child_id"
```

Use `-F`, not `-f`. `-F` performs type conversion, so the id is sent as a JSON
number; `-f` would send it as a string and the request is rejected.

That attaches `#124` as a child of `#40`. Verify — the core requires reading back
anything automation claimed:

```
gh api repos/{owner}/{repo}/issues/40/sub_issues --jq '.[] | "#\(.number)\t\(.state)\t\(.title)"'
```

### Remove a child

```
child_id=$(gh api repos/{owner}/{repo}/issues/124 --jq .id)
gh api --method DELETE repos/{owner}/{repo}/issues/40/sub_issue -F sub_issue_id="$child_id"
```

### Re-parenting

There is no move operation. Remove from the old parent, add to the new one, in
that order — a child may have only one parent, and adding while still attached
elsewhere fails rather than reassigning.

### Finding a child's parent

Listing children is straightforward; going the other way is not as well served.
The REST issue object exposes a `sub_issues_summary` object
(`{total, completed, percent_completed}`) on a parent, and current GraphQL
schemas expose `Issue.parent` and `Issue.subIssues`.

**Verified on github.com, 2026-09-22, by schema introspection:** `Issue.parent`,
`Issue.subIssues` and `Issue.subIssuesSummary` are all present in the GraphQL
schema. The REST `sub_issues_summary` object is **conditional** — it was absent
from a sampled issue that has no children, so a script must treat its absence as
"no sub-issue data on this response", never as "this issue has no children".

The sub-issues API is newer than the rest of the issues API and its read-side
field names have moved before, so re-check rather than trusting this paragraph —
especially on GitHub Enterprise Server, which lags github.com:

```
gh api graphql -f query='{ __type(name: "Issue") { fields { name } } }' --jq '.data.__type.fields[].name'
```

The approach below sidesteps the question entirely by deriving the child set from
the documented list endpoint, which is why it is the one the orphan sweep uses.

## Task lists: the older, weaker mechanism

Before sub-issues, parent-child was expressed by writing checkbox references in
the parent's body:

```
## Children

- [ ] #124 Classify transient vs permanent upstream failures
- [x] #125 Bounded retry with backoff
- [ ] #126 Quarantine permanently failing records
```

GitHub renders a progress bar and adds a backlink on each referenced issue. What
it does not do:

- **The checkbox and the issue state are independent.** `#125` above is ticked;
  nothing guarantees it is closed, and nothing unticks it if it reopens. Two
  claims about one fact, drifting apart — the failure `status-vocabulary` warns
  about, in miniature.
- **There is no API.** Reading the relationship means parsing Markdown out of a
  body. Writing it means a read-modify-write of the whole body, which races with
  anyone else editing it.
- **A child can appear under several parents,** because nothing enforces
  single-parent.

Task lists are still the right choice in three cases:

1. **The children are not issues.** A checklist of acceptance criteria or
   deployment steps belongs in the body. Making each step an issue to get a
   sub-issue link is worse.
2. **Sub-issues are unavailable** on your GitHub deployment. Enterprise Server
   lags GitHub.com on this feature; if the POST returns 404 on an issue that
   exists, that is the likely cause rather than a bad id.
3. **Cross-repository grouping.** A body reference to `<owner>/<other-repo>#12`
   always renders. Whether the sub-issues API accepts a child in a different
   repository has changed over time — **verify against your own deployment** with
   a single test call before designing a cross-repo hierarchy around it.

Where both exist, the sub-issue link is authoritative and the task list is
decoration. Do not maintain both for the same set of children.

## The orphan sweep

The core mandates this, periodically and as part of the gate. Orphan on GitHub
means: open, no milestone, and not a sub-issue of anything.

It must be a live query. There is no cached parent list here, and there must not
be one.

```
repo_open=$(gh issue list --state open --limit 500 --json number --jq '.[].number')

children=$(for n in $repo_open; do
  gh api "repos/{owner}/{repo}/issues/$n/sub_issues" --jq '.[].number' 2>/dev/null
done | sort -u)

no_milestone=$(gh issue list --state open --search "no:milestone" --limit 500 --json number --jq '.[].number' | sort -u)

comm -23 <(printf '%s\n' $no_milestone | sort) <(printf '%s\n' $children | sort)
```

The output is the orphan list: open issues with neither container. For each one,
the core says decide — and decide now, not later:

| Decision | Action |
| --- | --- |
| Belongs to an iteration | `gh issue edit <n> --milestone "2026.Q1"` |
| Is part of a larger piece of work | Add as a sub-issue of that parent, per above. |
| Is genuinely top level | Leave it, and say so in a comment. The core requires explicit human approval before creating a top-level item; recognising an existing one as top level deserves the same sentence of justification. |
| Should not be done | `gh issue close <n> --reason "not planned" --comment "<why>"` |

Cost note: the child-set loop makes one API call per open issue. On a repository
with hundreds of open issues that is slow and consumes REST rate limit. It is
still the right shape — a cached child set is the thing the core forbids. Narrow
the sweep instead: run it per milestone, per label, or over issues created since
a date.

**Do not stop at `--limit 500` and report the result as clean.** If the count of
open issues equals the limit, the sweep read a truncated backlog. Raise the
limit or narrow the query, and say which you did.

### A parent is not a valid parent just because it exists

The core's sharpest point: an issue carrying a parent reference reads as
compliant and may not be. A closed parent is an orphan wearing a badge. Check the
parent's state, not merely its presence:

```
gh api repos/{owner}/{repo}/issues/40 --jq '{number, state, state_reason, title}'
```

A child whose parent is `closed` — for either reason — is re-parented, the same
as a child with no parent at all.

## Auditing parents

### Children all closed, parent still open

The parent is done and nobody said so, or the parent has residual work that is
not represented as a child. Both are worth knowing.

```
for p in $(gh issue list --state open --limit 200 --json number --jq '.[].number'); do
  states=$(gh api "repos/{owner}/{repo}/issues/$p/sub_issues" --jq '[.[].state] | @csv' 2>/dev/null)
  case "$states" in
    ""|"[]") continue ;;
    *open*) continue ;;
    *) echo "#$p — all children closed, parent still open" ;;
  esac
done
```

For each hit, read the parent and choose: close it with
`--reason completed`, or comment saying what remains and add that remainder as a
child so the state stops lying.

### Parent closed, children still open

The converse, and the more damaging one — the children are now invisible to
anyone browsing by parent, and they will not appear in a rollup:

```
for p in $(gh issue list --state closed --limit 200 --json number --jq '.[].number'); do
  open_kids=$(gh api "repos/{owner}/{repo}/issues/$p/sub_issues" --jq '[.[] | select(.state == "open") | .number] | join(",")' 2>/dev/null)
  [ -n "$open_kids" ] && echo "#$p closed but children still open: $open_kids"
done
```

Repair is one of two things, never both: reopen the parent
(`gh issue reopen <p>`) because the work is not actually finished, or re-parent
the open children somewhere live. Leaving them attached to a closed parent is the
state this audit exists to eliminate.

### The quick per-issue check

When you only care about one issue — the gate's case — the summary is enough,
subject to the field-name caveat above:

```
gh api repos/{owner}/{repo}/issues/40 --jq '.sub_issues_summary'
```

If that returns `null` on a GitHub deployment where sub-issues work, the field is
named differently there; fall back to listing `sub_issues` and counting.
