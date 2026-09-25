# Label taxonomy: create, rename, delete

Commands for setting up the namespaced labels that `backlog-hygiene-github` uses. Run each block
once per repository; `--force` updates a label that already exists, so re-running is safe.

## Status: one per open issue

```bash
gh label create "status:backlog"     --color "EDEDED" --description "Captured, not yet prioritised" --force
gh label create "status:ready"       --color "0E8A16" --description "Prioritised and startable" --force
gh label create "status:in-progress" --color "1D76DB" --description "Someone is working this now" --force
gh label create "status:in-review"   --color "5319E7" --description "Reviewable change exists and is linked" --force
gh label create "status:parked"      --color "795548" --description "Deferred; revisit condition in a comment" --force
```

There is no `status:done`, `status:declined` or `status:blocked`. Done and declined are `closed`
plus a reason, and a label would be a second source of truth. Blocked is a facet, not a state.

## Blocked facet (optional)

Only for repositories that cannot use native blocked-by links, or want a filter on top of them:

```bash
gh label create "blocked" --color "B60205" --description "Blocker named in a comment or blocked-by link" --force
```

It carries no `status:` prefix, so the one-status-label sweep never counts it.

## Type: only without native issue types

Use these when `gh api repos/{owner}/{repo}/issue-types --jq '.[].name'` returns nothing (a
personal-account repository, or an organization with types turned off):

```bash
gh label create "type:bug"     --color "D73A4A" --description "Defect repair" --force
gh label create "type:feature" --color "A2EEEF" --description "New capability" --force
gh label create "type:chore"   --color "FEF2C0" --description "Dependencies, tooling, housekeeping" --force
gh label create "type:docs"    --color "0075CA" --description "Documentation-only change" --force
gh label create "type:spike"   --color "D4C5F9" --description "Time-boxed investigation; output is a decision" --force
```

In search, filter these with `label:"type:bug"`. The bare qualifier `type:"Bug"` matches the native
issue type, not the label.

## Priority and area

```bash
gh label create "priority:p0" --color "B60205" --description "Drop everything" --force
gh label create "priority:p1" --color "D93F0B" --description "This iteration" --force
gh label create "priority:p2" --color "FBCA04" --description "Soon, not now" --force
gh label create "priority:p3" --color "C2E0C6" --description "Someday" --force
gh label create "area:api"    --color "BFD4F2" --description "API surface" --force
```

Add `area:` labels to match the system's real components.

Colours are hex without a leading `#`. With `#`, the value must be quoted, or the shell reads the
rest of the line as a comment.

## Read back

```bash
gh label list --limit 200 --json name,description --jq '.[] | "\(.name)\t\(.description)"'
```

## Rename, then delete

Renaming keeps the label on every issue that carries it, so rename rather than create and relabel:

```bash
gh label edit "status:wip" --name "status:in-progress"
```

Delete only after confirming nothing carries the label:

```bash
gh issue list --state all --label "status:wip" --limit 1
gh label delete "status:wip" --yes
```

## Without gh

The GitHub MCP server's `labels` toolset (not in its default set) has `list_label`, `get_label` and
`label_write` (`method` `create`, `update` or `delete`; `color` without `#`). Without it, print the
commands above for the user.
