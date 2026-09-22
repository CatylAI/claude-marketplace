# issue-tracker-core

Vendor-neutral issue-tracker discipline for Claude Code. It encodes the habits that
survive a tracker migration: requiring a real issue before code is written, deriving
branch and pull-request names from the issue key, using a lifecycle vocabulary whose
states mean something checkable, keeping every item parented, and treating the issue
as the durable record of the work.

No tracker product, project key, issue-type ID or transition ID appears anywhere in
this plugin. Tracker-specific adapters sit on top and supply those.

## Skills

| Skill | Use it when |
| --- | --- |
| `pre-work-gate` | Before any development task — confirm the issue exists, is assigned, is in a workable state, and actually covers the request. |
| `branch-and-title-conventions` | Naming a branch or worktree, choosing a commit scope, or writing a pull request title. |
| `status-vocabulary` | Deciding what a lifecycle state means and what must be true before advancing. |
| `parent-child-hygiene` | Creating an item or auditing a backlog — every item has a live parent, found by query. |
| `issue-lifecycle` | Commenting at start, handoff and completion so the tracker carries the history. |

## When to use it

Load this plugin in any repo where work is tracked in an issue system — GitHub Issues,
a hosted enterprise tracker, a lightweight board, or a plain text backlog. The rules
are written to be executable against all of them.

## When not to use it

- Throwaway spikes in a scratch repository with no tracker at all.
- Tracker-specific automation (creating items, moving states through an API). That is
  an adapter's job; this plugin tells the adapter what a correct move looks like.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Issue-key shape. Shared with the `dev-guardrails` plugin so branch parsing and commit-scope suggestions agree. |

## Dependencies

- `dev-standards` — supplies the Conventional Commits format that
  `branch-and-title-conventions` builds the issue-key scope on top of.

## License

MIT
