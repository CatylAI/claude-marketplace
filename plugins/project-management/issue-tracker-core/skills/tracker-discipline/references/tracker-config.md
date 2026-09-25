# Issue tracker: the project mapping

The skills in `issue-tracker-core` are written against the seven core states and a few settings
rather than against a tracker product. Each project records its answers once, in its
`CLAUDE.md`, so every session starts with them. The mapping lives in the project and not in the
plugin because an installed plugin is a cached copy that is replaced on every update.

## How the skills use it

1. Read the `## Issue tracker` section of the project's `CLAUDE.md` (repository root, or
   `.claude/CLAUDE.md`). In Claude Code the project `CLAUDE.md` is already in context at session
   start, so this is a lookup, not a tool call.
2. If the section is missing, or a needed row is empty, ask for those rows in one question and
   carry on with the answers.
3. Afterwards, offer to add or complete the section with the template below. Write it only when
   the user agrees.

Without a checkout (web, or a session with no repository) there is no `CLAUDE.md` to read: ask
for the rows, or ask the user to paste the section.

## Template

Copy this into the project's `CLAUDE.md` and replace every `<…>`. Keep a row and write `none`
when it does not apply, so the gap stays visible.

```markdown
## Issue tracker

| Setting | Value | Notes |
|---|---|---|
| Tracker | <github-issues / jira-tracker / other: <product> / none> | `none` turns the pre-work gate off for this repo |
| Project | <owner/repo, project key, or board> | Where new items are created |
| Ticket pattern | <regex, e.g. [A-Z][A-Z0-9]+-[0-9]+> | Keep equal to CLAUDE_TICKET_PATTERN if that is set |
| Intake state | <tracker state new items land in> | Maps to `backlog` |
| Parent mechanism | <sub-issue, parent field, epic, milestone, …> | How an item points at its parent |
| Top-level items | <item type that sits at the top; who approves a new one> | |

Status mapping (tracker name, or how the state is carried):

| Core state | Tracker |
|---|---|
| backlog | <…> |
| ready | <…> |
| in-progress | <…> |
| in-review | <…, e.g. "In Progress + linked PR" when there is no review state> |
| done | <…> |
| parked | <…> |
| declined | <…> |
```

## The ticket pattern

Claude learns the issue-key shape from the first of these that is set:

1. **The `Ticket pattern` row** of the `## Issue tracker` section. It works on every surface,
   because it is plain text in `CLAUDE.md` (or pasted in).
2. **The `CLAUDE_TICKET_PATTERN` environment variable**, Claude Code only. A skill cannot see
   environment variables directly; run `printenv CLAUDE_TICKET_PATTERN` in Bash to read it. A
   team sets it in the `env` block of `.claude/settings.json`, which applies to the session and
   its subprocesses. This is the variable the `dev-guardrails` hooks read for branch-name and
   commit-scope guidance.
3. **The default** `[A-Z][A-Z0-9]+-[0-9]+`, which matches keys such as `PROJ-123`.

If the row and the variable are both set and differ, use the row, and tell the user once that
`dev-guardrails` will keep using the variable until the two are aligned.

The key becomes a commit and title scope, so a pattern must match only letters, digits, `_`,
`/` and `-` (the scope charset in `dev-standards:commit-standards`). A tracker whose native
reference is `#123` uses a pattern such as `GH-[0-9]+` or `[0-9]+`; the `github-issues` adapter
explains the choice.

## Which skill reads which rows

| Skill | Rows it needs |
|---|---|
| `pre-work-gate` | Tracker, Ticket pattern, Status mapping, Parent mechanism |
| `branch-and-title-conventions` | Tracker, Ticket pattern |
| `tracker-discipline` | Project, Intake state, Parent mechanism, Top-level items, Status mapping |
