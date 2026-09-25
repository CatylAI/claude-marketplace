# The `## Issue tracker` section for a GitHub repository

`issue-tracker-core` reads its settings from the `## Issue tracker` section of the project's
`CLAUDE.md`. The generic template, the lookup order for the ticket pattern, and which skill reads
which row are in the core's `tracker-discipline` skill, `references/tracker-config.md`. This file
only fills that template in for GitHub Issues and explains the two GitHub-specific choices: the
ticket pattern and how the seven states are carried.

## Recommended section

Copy it into the project's `CLAUDE.md`, then adjust the rows marked "choose".

```markdown
## Issue tracker

| Setting | Value | Notes |
|---|---|---|
| Tracker | github-issues | |
| Project | <owner>/<repo> | Where new issues are created |
| Ticket pattern | GH-[0-9]+ | Choose: GH-[0-9]+ or [0-9]+ (see below). Branch key GH-123 means issue #123 |
| Intake state | open + `status:backlog` | |
| Parent mechanism | sub-issue | Choose: sub-issue, milestone, or sub-issue + milestone |
| Top-level items | <issue type Epic, or label `epic`>; approved by <who> | |

Status mapping:

| Core state | Tracker |
|---|---|
| backlog | open + `status:backlog` |
| ready | open + `status:ready` |
| in-progress | open + `status:in-progress` + assignee |
| in-review | open + `status:in-review` + a linked pull request (`linked:pr`) |
| done | closed, reason `completed` |
| parked | open + `status:parked` + a comment naming the revisit condition |
| declined | closed, reason `not planned` or `duplicate` |
```

When a Projects v2 board carries the state instead of labels, the Tracker column names the board's
Status options (for example `in-review = "In Review"`), and the Notes say which board. The
`backlog-hygiene-github` skill covers choosing between the two carriers.

## Ticket pattern: GitHub issues have no prefix

The core's default pattern, `[A-Z][A-Z0-9]+-[0-9]+`, matches keys such as `PROJ-123`. GitHub
issues are bare numbers written `#123`, so the default matches nothing on a GitHub branch and the
pre-work gate finds no key. Pick one of these per repository and record it in the row.

| Pattern | Branch and title | Trade-off |
|---|---|---|
| `GH-[0-9]+` (recommended) | `fix/GH-123-retry-worker`, `fix(GH-123): retry transient failures` | One translation step (`GH-123` is issue `#123`); the key cannot be confused with other numbers in a branch name. |
| `[0-9]+` | `fix/123-retry-worker`, `fix(123): retry transient failures` | No translation; also matches the `2` in `refactor/v2-parser` or a date, so confirm the number with the user rather than inferring it. |

`#123` itself cannot be the key: the commit-scope charset (`dev-standards:commit-standards`) allows
letters, digits, `_`, `/` and `-` only.

If the team also sets `CLAUDE_TICKET_PATTERN` (read by the `dev-guardrails` hooks), keep it equal to
the row.

## Closing references use GitHub's own form

Whichever pattern the repo uses, a pull request body closes an issue only with GitHub's reference
form: `Fixes #123`, or `Fixes <owner>/<repo>#123` for an issue in another repository. `Fixes GH-123`
closes nothing, because GitHub does not know the synthetic prefix. Keep `GH-123` for branch names,
commit scopes and titles, and `#123` in bodies and comments where GitHub does the linking.

Closing keywords (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`,
`resolved`) act only when the pull request merges into the repository's default branch.
