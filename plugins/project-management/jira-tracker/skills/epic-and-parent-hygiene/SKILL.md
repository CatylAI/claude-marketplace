---
name: epic-and-parent-hygiene
description: "Enforce parent-child hygiene on Jira — work out whether your project links children to epics through the parent field or a legacy Epic Link custom field, run the two-stage candidate-parent query live instead of caching an epic list, set and verify a parent, distinguish hierarchy from issue links, and sweep a backlog for orphans and for parents whose children have all closed. Use when creating a Jira issue, when an issue has no parent or a dead one, or when auditing a Jira backlog."
license: MIT
---

# Epic and Parent Hygiene on Jira

`parent-child-hygiene` states three rules: every non-top-level item has a parent,
the candidate-parent list is a query rather than a table, and an orphan is a
defect fixed when found. Jira gives you a hierarchy to satisfy them with — and
the hierarchy is not the same shape in every project on the same site.

Read the core for why. Read this for which field, and which query.

## Jira's hierarchy, and the thing that makes it awkward

Jira's standard hierarchy has three levels:

| Level | Issue types | Parent |
| --- | --- | --- |
| Sub-task | The project's sub-task types | A standard issue, always required |
| Standard | Story, Task, Bug, and whatever else the project defines | An epic-level issue — this is the level the core's rule is about |
| Epic | The project's epic type | None, unless the site has levels above epic |

On Jira Premium a site can define **additional levels above epic** — an
initiative tier, a theme tier, whatever the organisation named them. Where those
exist, "epic" is no longer the top and the core's "never create a top-level item
without explicit human approval" applies to the highest level, not to epics.
Check before assuming:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes"
```

Each entry carries `hierarchyLevel`: sub-tasks are `-1`, standard issues are `0`,
epics are `1`, and anything above epic is `2` or higher. **That field, not the
type's name, is what tells you where an issue type sits.** A project can name a
standard-level type "Epic Task" and it is still standard level.

## Company-managed and team-managed projects differ, and it matters here

This is the real difference between Jira and every other tracker this catalog
adapts, and it is worth stating plainly rather than smoothing over: **two
projects on the same Jira site can express the same parent-child relationship
through two different fields.**

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/project/<PROJECT_KEY>?expand=description" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["key"], "| style:", d.get("style"), "| simplified:", d.get("simplified"))'
```

`style` distinguishes the two families — a company-managed project reports
`classic`, a team-managed project reports `next-gen`. What follows from that:

| | Team-managed (`next-gen`) | Company-managed (`classic`) |
| --- | --- | --- |
| Who configures it | The project's own admins, per project | A Jira admin, through shared schemes |
| Statuses and workflow | Local to the project | Shared schemes; the same status may exist in many projects |
| Issue-type ids | Local to the project | Often shared across projects |
| Child → epic link | The `parent` field | The `parent` field on modern projects; **a legacy `Epic Link` custom field on older ones** |
| Components | Not available | Available |
| Fields | Project-scoped | Site-scoped `customfield_NNNNN` |

**The Epic Link seam.** Historically, company-managed projects linked a story to
an epic through a custom field literally named *Epic Link*, with an id of the
form `customfield_NNNNN`, while team-managed projects used `parent`. Atlassian
unified on `parent`, and on a current site `parent` is what you should be writing.
But `Epic Link` still exists on sites that have been running for years, it still
appears in `GET /rest/api/3/field`, and older automation and saved filters still
reference it.

**Flagged as the thing to verify rather than assume:** whether your
company-managed project accepts `parent` for epic linking, whether it still
exposes `Epic Link`, and whether the two stay in sync if both are present. Do not
guess. Ask the project:

```bash
# Which fields does this issue type actually accept on create?
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/createmeta/<PROJECT_KEY>/issuetypes/<ISSUE_TYPE_ID>" \
  | python3 -c 'import sys,json; [print(f.get("fieldId"), "|", f.get("name"), "| required:", f.get("required")) for f in json.load(sys.stdin).get("fields",[])]'
```

```bash
# Does a legacy Epic Link field exist on this site, and what is its id?
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/field" \
  | python3 -c 'import sys,json; [print(f["id"], "|", f["name"]) for f in json.load(sys.stdin) if "epic" in f["name"].lower() or "parent" in f["name"].lower()]'
```

**This plugin ships no `customfield_NNNNN` value.** It cannot: that number is
allocated per site and means something entirely different on the next one. The
two commands above are the answer, and running them takes less time than
debugging a write that silently set the wrong field.

An existing issue tells you which mechanism its project uses, too — fetch one
that is already parented and see which field carries the link:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>?fields=parent,issuetype,status" \
  | python3 -c 'import sys,json; f=json.load(sys.stdin)["fields"]; p=f.get("parent"); print("parent:", (p or {}).get("key"), "| type:", f["issuetype"]["name"])'
```

### Sub-tasks are a separate case

A sub-task's `parent` is set at creation and is **required**. Moving a sub-task
to a different parent is not a plain field edit in every Jira configuration — it
has historically been the *Move* operation rather than an edit, and whether a
`PUT` on `fields.parent` is accepted for a sub-task varies. **Flagged:** try the
edit, read it back, and fall back to recreating the sub-task under the right
parent if the edit is rejected or silently ignored. Do not assume either
behaviour.

### Hierarchy is not the same thing as an issue link

Jira also has **issue links** — `blocks`, `is blocked by`, `relates to`,
`duplicates`, `clones` — through a separate endpoint:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issueLink" \
  --data '{
    "type":         { "name": "Blocks" },
    "inwardIssue":  { "key": "PROJ-124" },
    "outwardIssue": { "key": "PROJ-125" }
  }'
```

Link type names are per-site; read them from `GET /rest/api/3/issueLinkType`.

**An issue link does not satisfy the core's parent requirement.** A link is a
peer relationship: it does not roll up, it does not appear in an epic's progress,
and it does not make the issue findable from above. "It's linked to the epic" is
the most common way an orphan reads as compliant. Check `fields.parent`, not the
link list.

## The candidate-parent list is a QUERY, not a table

`parent-child-hygiene` is unambiguous: do not cache a list of candidate parents
in a skill, a config file or a memory note. **Epics open, close and get renamed
constantly; a cached list is wrong within weeks and is trusted while wrong.** A
staleness note makes the staleness documented, which is a different thing —
checking a date is a step, and skipping a step is free.

**There is deliberately no epic table in this plugin, and there must not be one.**

Run the two-stage query. See `jira-jql` for the endpoint and its pagination.

**Stage 1 — the shortlist.** Narrow to the parents that are right for most work,
so the result is short enough to present as an actual choice — five to ten
entries:

```
project = <PROJECT_KEY> AND issuetype = Epic
  AND statusCategory != Done
  AND status NOT IN ("<DEFERRED_STATUS>", "<DECLINED_STATUS>")
  AND updated >= -90d
ORDER BY updated DESC
```

Narrow further on whatever your board's equivalent of a current bucket is — a
label, a fix version, a component, a summary pattern. Which one that is depends
on the project; pick it once and write it into the repository's own docs, not
into this skill.

**Stage 2 — the full set.** Only when nothing in the shortlist fits. Unfiltered
except for liveness:

```
project = <PROJECT_KEY> AND issuetype = Epic
  AND statusCategory != Done
  AND status NOT IN ("<DEFERRED_STATUS>", "<DECLINED_STATUS>")
ORDER BY updated DESC
```

Why two stages: **a list of eighty candidates is not a choice.** An instruction
to "present the list" that cannot be followed is an instruction that gets
skipped, and the skipped version of this instruction is an orphan. Mature Jira
projects routinely carry dozens of open epics, which is exactly why stage 1
exists.

Three things about those predicates, each of which is a real defect when got
wrong:

- **`statusCategory != Done`, not `status != Done`.** The name filter matches
  only the literal status called `Done` and lets every other terminal status
  through. See `jira-jql`.
- **Deferred and declined statuses are excluded by name** because they do not
  always sit in the `Done` category, so the category filter alone still returns
  them. Neither is ever a valid parent. Read the project's status set with
  `GET /rest/api/3/status` and substitute the real names — do not guess them.
- **Jira accepts a parent in a terminal state silently.** No error, no warning.
  The issue lands under a closed epic nobody reads again. Verify the status you
  got back rather than trusting that the filter did its job.

## Setting a parent

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X PUT -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>" \
  --data '{"fields": {"parent": {"key": "<EPIC_KEY>"}}}'
```

On a project that still uses the legacy field, the same edit takes the field id
you discovered above instead, with the epic key as a bare string:

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X PUT -H "Content-Type: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>" \
  --data '{"fields": {"<EPIC_LINK_FIELD_ID>": "<EPIC_KEY>"}}'
```

`PUT /rest/api/3/issue/<KEY>` returns `204 No Content` on success — **no body,
so no confirmation of what it set.** The core requires reading back anything
automation claimed to do, and here that read-back does double duty: it confirms
the write *and* checks the parent is alive.

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json" \
  "https://<SITE>.atlassian.net/rest/api/3/issue/<KEY>?fields=parent" \
  | python3 -c 'import sys,json; p=json.load(sys.stdin)["fields"].get("parent"); print("NO PARENT") if not p else print(p["key"], "|", p["fields"]["status"]["name"], "|", p["fields"]["status"]["statusCategory"]["key"])'
```

If that prints a `done` category, you have just parented live work to a closed
epic. Re-parent it now — the core says an orphan is fixed when found, and this is
an orphan with a badge on.

### Setting the parent at creation, not afterwards

`parent-child-hygiene` step 5: *set the parent as part of creating the item, not
as a follow-up. A follow-up step is the step that does not happen.* In Jira that
means `parent` goes in the create body alongside `project`, `issuetype`,
`assignee` and `summary` — see `jira-issue-lifecycle`.

## Procedure when creating an issue

1. **Decide whether the new issue is itself top level.** Top-level issues are the
   only ones exempt from parenting, and creating one is a planning decision:
   **never create an epic — or a higher-level issue where the site has one —
   without explicit human approval.**
2. Otherwise run the stage-1 query.
3. Present the shortlist, or propose one candidate from context and say why.
4. If nothing fits, run stage 2. If nothing there fits either, ask whether a new
   top-level issue is warranted — and wait for the answer.
5. Put `parent` in the create call.
6. Read the created issue back and confirm the parent landed and is live.

## The orphan sweep

`jira-jql` carries the queries. What this skill adds is what to do with each
row, because the core is explicit that an orphan noted and left is not fixed.

| Finding | Repair |
| --- | --- |
| No parent, not top level | Run the stage-1 query and set one. |
| Parent in a `done` category | Re-parent to a live epic. A closed parent is an orphan wearing a badge. |
| Parent deferred or declined | Same repair. Neither is ever a valid parent. |
| Parent key does not resolve | The epic was deleted or moved to another project. Re-parent. |
| Genuinely top level | Leave it, and say so in a comment. The core requires explicit approval to *create* a top-level item; recognising an existing one as top level deserves the same sentence of justification. |
| Should not be done at all | Close it with the not-doing resolution and a reason — see `jira-issue-lifecycle`. Leaving it open keeps it surfacing in every prioritisation pass. |

## Auditing parents

### Children all closed, the epic still open

Either the epic is done and nobody said so, or it has residual work that is not
represented as a child. Both are worth knowing, and the second is the more
useful finding.

For a candidate epic, count its live children:

```
project = <PROJECT_KEY> AND parent = <EPIC_KEY> AND statusCategory != Done
```

An empty result on an open epic is the hit. Read the epic and choose: close it
with a completion resolution, or comment saying what remains and create that
remainder as a child so the state stops lying.

### The epic closed, children still open

The converse, and the more damaging one — those children are now invisible to
anyone browsing by epic, and they will not appear in a rollup. `jira-jql`'s
two-query form finds them.

Repair is one of two things, never both: reopen the epic because the work is not
actually finished, or re-parent the open children somewhere live. Leaving them
attached to a closed epic is the state this audit exists to eliminate.

### Progress is not a completeness check

An epic's progress bar counts the children it has. It says nothing about the work
that was never filed as a child, which is precisely the work an audit is looking
for. A 100% epic with a live branch against it is the common shape of this.

## Handoffs

- The endpoint, pagination and the sweeps themselves: `jira-jql`.
- Creating, transitioning, commenting and closing: `jira-issue-lifecycle`.
- Why a parent at all, and why the list is a query: `parent-child-hygiene` in
  `issue-tracker-core`.
