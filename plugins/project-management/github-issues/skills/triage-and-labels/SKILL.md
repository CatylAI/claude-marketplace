---
name: triage-and-labels
description: "Represent the core status vocabulary on GitHub, which has only open and closed, using a namespaced label taxonomy — create and maintain labels idempotently with gh label, run a triage sweep for issues with no label, assignee or milestone, apply and remove labels, detect and repair conflicting status labels, and decide when a Projects v2 single-select field is the better carrier instead. Use when triaging a GitHub backlog, setting up labels in a fresh repository, or moving an issue between lifecycle states."
license: MIT
---

# Triage and Labels

## The problem this skill exists to solve

`status-vocabulary` in `issue-tracker-core` defines seven states — backlog,
ready, in progress, in review, done, parked, declined — and insists each is a
*claim about reality* that a reader will act on without verifying.

GitHub Issues has two states: `open` and `closed`. Closed carries one bit of
extra information, `state_reason`, which is `completed` or `not_planned`.

So GitHub natively represents exactly three of the seven: done (`closed` +
`completed`), declined (`closed` + `not_planned`), and "some open state,
unspecified". The other four — backlog, ready, in progress, in review, plus
parked — have no native carrier. They must be layered on with labels or with a
Projects v2 field, and the layer is advisory: nothing in GitHub enforces it.

Be honest about that rather than pretending the mapping is clean. A label that
says `status:in-review` when no pull request exists is exactly the false claim the
core warns about, and GitHub will not stop you making it.

## Mapping the vocabulary

| Core state | GitHub representation | Native? |
| --- | --- | --- |
| Backlog | open, label `status:backlog` | No |
| Ready | open, label `status:ready` | No |
| In progress | open, label `status:in-progress`, assignee set | No |
| In review | open, label `status:in-review`, a linked open pull request | No |
| Done | closed, `state_reason: completed` | Yes |
| Parked | open, label `status:parked`, comment naming the revisit condition | No |
| Declined | closed, `state_reason: not_planned` | Yes |

One addition GitHub practice needs and the core does not name: `status:blocked`.
The core routes blocked work back to ready or parked with the blocker named. If
your team wants blocked visible as its own filter, add the label — but treat it
as a facet on ready, not a sixth lifecycle state, or you have done exactly what
rule 2 of `status-vocabulary` forbids.

## Why namespaced labels

Flat labels (`bug`, `urgent`, `done`, `frontend`) fail at three things a
namespaced set does for free.

1. **Grouping.** `gh label list` sorts alphabetically, so `status:*` labels sit
   together and a reader sees the whole vocabulary at once instead of hunting for
   it among area tags.
2. **Filterable as a class.** `gh issue list --search 'is:open -label:status:backlog -label:status:ready'` is
   expressible. "Every label that happens to be a status" is not.
3. **Conflict detection is mechanical.** "More than one label whose name starts
   with `status:`" is a one-line check. "More than one label that is semantically
   a status" is a judgement call, and judgement calls do not run in a sweep.

The colon is not special to GitHub — it is an ordinary character in a label name.
The convention is entirely ours, which is why the repair procedure below matters.

### The four namespaces

| Prefix | Answers | Cardinality | Examples |
| --- | --- | --- | --- |
| `status:` | Where is it in the lifecycle? | Exactly one, on every open issue | `status:backlog`, `status:ready`, `status:in-progress`, `status:in-review`, `status:parked`, `status:blocked` |
| `type:` | What kind of work is it? | Exactly one | `type:bug`, `type:feature`, `type:chore`, `type:docs`, `type:spike` |
| `priority:` | How urgent? | Zero or one | `priority:p0`, `priority:p1`, `priority:p2`, `priority:p3` |
| `area:` | What part of the system? | Zero or more | `area:api`, `area:ingestion`, `area:infra`, `area:docs` |

`area:` is the only genuinely multi-valued namespace. Resist adding a fifth
namespace: each one is another thing a triager must decide, and a taxonomy
nobody completes is a taxonomy that lies.

## Creating the labels idempotently

`gh label create` fails if the label exists. `--force` makes it update instead,
which is what you want in a script that may run against a repository that is
half set up:

```
gh label create "status:backlog"    --color "EDEDED" --description "Captured, not yet prioritised" --force
gh label create "status:ready"      --color "0E8A16" --description "Prioritised and startable" --force
gh label create "status:in-progress" --color "1D76DB" --description "Someone is actively working this now" --force
gh label create "status:in-review"  --color "5319E7" --description "Reviewable artefact exists and is linked" --force
gh label create "status:blocked"    --color "B60205" --description "Blocked; blocker named in a comment" --force
gh label create "status:parked"     --color "795548" --description "Deferred; revisit condition named in a comment" --force
```

```
gh label create "type:bug"     --color "D73A4A" --description "Defect repair" --force
gh label create "type:feature" --color "A2EEEF" --description "New capability" --force
gh label create "type:chore"   --color "FEF2C0" --description "Dependencies, tooling, housekeeping" --force
gh label create "type:docs"    --color "0075CA" --description "Documentation-only change" --force
gh label create "type:spike"   --color "D4C5F9" --description "Time-boxed investigation, output is a decision" --force
```

```
gh label create "priority:p0" --color "B60205" --description "Drop everything" --force
gh label create "priority:p1" --color "D93F0B" --description "This iteration" --force
gh label create "priority:p2" --color "FBCA04" --description "Soon, not now" --force
gh label create "priority:p3" --color "C2E0C6" --description "Someday" --force
```

Colours are hex without the leading `#`. `gh` accepts a leading `#` too, but it
must then be quoted or the shell treats the rest of the line as a comment — drop
it and avoid the class of bug entirely.

There is deliberately no `status:done` or `status:declined` label. Those states
are `closed` plus a reason, and duplicating them as labels creates a second
source of truth that will disagree with the first.

### Read back what exists

```
gh label list --limit 200 --json name,color,description --jq '.[] | "\(.name)\t\(.description)"'
```

Just the status namespace:

```
gh label list --limit 200 --json name --jq '.[].name | select(startswith("status:"))'
```

### Renaming and editing

```
gh label edit "status:in-review" --description "Awaiting judgement by someone else; pull request linked"
```

```
gh label edit "status:wip" --name "status:in-progress"
```

Renaming preserves the label on every issue carrying it, which is why renaming
beats create-new-and-relabel. Deleting does not:

```
gh label delete "status:wip" --yes
```

Delete only after confirming nothing carries it:

```
gh issue list --state all --label "status:wip" --limit 1
```

## The triage sweep

Triage is the pass that turns captured issues into workable ones. It is
read-heavy and decision-light: each issue gets a `type:`, a `status:`, and either
a parent or a reason it has none.

### Find what needs triage

Untriaged means no label at all:

```
gh issue list --state open --search "no:label" --limit 100 --json number,title,createdAt,author \
  --jq '.[] | "#\(.number)\t\(.createdAt[0:10])\t\(.author.login)\t\(.title)"'
```

Labelled but with no lifecycle claim — the more common and more dangerous case,
because these look triaged:

```
gh issue list --state open --limit 200 --json number,title,labels \
  --jq '[.[] | select([.labels[].name | select(startswith("status:"))] | length == 0)] | .[] | "#\(.number)\t\(.title)"'
```

Unassigned work that claims to be in progress:

```
gh issue list --state open --search 'no:assignee label:"status:in-progress"' --limit 100 --json number,title \
  --jq '.[] | "#\(.number)\t\(.title)"'
```

No milestone — the GitHub spelling of the core's orphan sweep; see
`milestones-and-sub-issues` for the full procedure:

```
gh issue list --state open --search "no:milestone" --limit 100 --json number,title \
  --jq '.[] | "#\(.number)\t\(.title)"'
```

Stale in-progress, which is the single most useful triage query because it finds
the states that are lying:

```
gh issue list --state open --search 'label:"status:in-progress" updated:<2026-01-01' --limit 100 --json number,title,updatedAt \
  --jq '.[] | "#\(.number)\t\(.updatedAt[0:10])\t\(.title)"'
```

Substitute a real cutoff date — `updated:<YYYY-MM-DD` takes a literal date, not a
relative expression.

Note that `--search` and the convenience flags share one query. Mixing
`--label` with a `--search` string that also carries `label:` qualifiers works
but is hard to read; pick one form per command.

### What a triage decision must record

A triage pass that only applies labels has thrown away its reasoning. Each
decision records, at minimum:

- the `type:` and the `status:` chosen;
- the parent, or a stated reason there is none;
- for anything not going to `status:ready`, **why** — as a comment, because the
  core's rule is that the issue is the durable record and the triage meeting is
  not.

A decline is a decision too, and it is recorded by closing with a reason rather
than by letting the issue rot in the backlog:

```
gh issue close 87 --reason "not planned" --comment "Declining: the workaround in #91 removes the need, and the requester confirmed. Leaving this open would keep it surfacing in every prioritisation pass."
```

### Applying the decision

```
gh issue edit 88 \
  --add-label "type:bug,status:ready,priority:p1,area:ingestion" \
  --milestone "2026.Q1" \
  --add-assignee @me
```

Moving between states is a remove plus an add, in one command so there is no
window where the issue carries both or neither:

```
gh issue edit 88 --remove-label "status:ready" --add-label "status:in-progress"
```

Batch application over a sweep's output:

```
gh issue list --state open --search "no:label" --limit 100 --json number --jq '.[].number' \
  | while read -r n; do gh issue edit "$n" --add-label "status:backlog"; done
```

Run the read query alone first and look at it. A `while` loop over a query you
have not inspected will happily relabel two hundred issues.

## The honest caveat: nothing enforces this

Labels are advisory. GitHub has no concept of a label group, no mutual exclusion,
no required label, and no validation on `gh issue edit`. An issue can carry
`status:ready` and `status:in-progress` and `status:parked` simultaneously, and
every view in the product will render all three without complaint.

That is not a reason to skip the taxonomy — it is a reason to sweep for the
violation, because the conflict will happen. It happens when two people triage the
same issue, when a half-finished `gh issue edit` adds without removing, and when
an automation applies a label and its removal step fails.

### Detect conflicting status labels

```
gh issue list --state open --limit 500 --json number,title,labels \
  --jq '[.[] | {number, title, statuses: [.labels[].name | select(startswith("status:"))]} | select(.statuses | length > 1)] | .[] | "#\(.number)\t\(.statuses | join(" + "))\t\(.title)"'
```

Empty output is the passing result. Raise `--limit` if the repository has more
than 500 open issues, or the sweep is reporting on a subset and calling it clean.

The same query shape finds duplicate `type:` labels — change the prefix in the
two `startswith` calls.

### Repair one

Repair is not automatable, because choosing which of two claims is true requires
reading the issue. Read it, decide, then:

```
gh issue view 88 --comments
```

```
gh issue edit 88 --remove-label "status:ready" --remove-label "status:parked" --add-label "status:in-progress"
```

Then record why, if the conflict itself was informative — for example, that the
issue was parked and someone resumed it without saying so.

## When a Projects v2 field is the better carrier

Labels are the right choice when:

- the repository is the unit of work and nobody is coordinating across repos;
- contributors outside the team need to see state without project access;
- you want state queryable with `gh issue list --search`, which does not see
  project fields at all.

A Projects v2 **single-select status field** is the better carrier when:

- **Mutual exclusion matters.** A single-select field holds exactly one option.
  The conflict this skill spends a whole section detecting and repairing cannot
  occur. If you have run the conflict sweep twice and found hits both times, that
  is the signal to move.
- **Work spans repositories.** One project board holds issues from many repos;
  labels are per-repository and the taxonomies drift apart immediately.
- **You need ordering, iteration or a numeric field.** Labels have none of these.
- **The board is where the team actually looks.** A status label nobody reads is
  bookkeeping.

The costs are real: Projects v2 is GraphQL-only, needs a scope that a default
`gh auth login` does not grant, and its field values are invisible to
`gh issue list`. See `projects-v2` for the queries and mutations.

**Running both is a supported choice and a maintenance burden.** If you do, name
one as authoritative — in the repository's own contributing docs, not in this
skill — and treat the other as a projection that may lag. Two carriers with no
stated precedence is the same defect as two conflicting status labels, one level
up.
