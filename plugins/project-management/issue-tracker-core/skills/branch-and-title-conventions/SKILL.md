---
name: branch-and-title-conventions
license: MIT
description: How to derive a branch name, commit scope and pull request title from an issue key, and keep the key recoverable from the branch so every downstream artefact can be generated instead of remembered. Use when creating a branch or worktree, writing a pull request title, or recovering an issue key from an existing branch.
---

# Branch and Title Conventions

One rule underneath all of this: **the issue key must be recoverable from the
branch name.** Everything downstream — commit scope, pull request title,
changelog entry, release note, the tracker comment linking the two — is then a
derivation rather than an act of memory.

## The key shape is configurable

Do not hardcode one project's prefix. The key shape comes from
`CLAUDE_TICKET_PATTERN`, the same variable the sibling `dev-guardrails` plugin
reads, so branch parsing and commit-scope suggestion agree:

| Variable | Default | Notes |
| --- | --- | --- |
| `CLAUDE_TICKET_PATTERN` | `[A-Z][A-Z0-9]+-[0-9]+` | Matches `PROJ-123`, `A1-7`, `PLATFORM2-4501`. |

Trackers that number issues plainly can set `[0-9]+`; trackers with an
underscore form can set `ISSUE_[0-9]+`. Everything below says "the key" and means
whatever that pattern matches.

## Branch names

```
<prefix>/<KEY>-<short-summary>
```

| Prefix | Use for |
| --- | --- |
| `feature` | New capability. |
| `fix` | Defect repair. |
| `refactor` | Behaviour-preserving restructuring. |
| `chore` | Dependencies, tooling, housekeeping. |
| `docs` | Documentation-only change. |

`<short-summary>` is two to five kebab-case words — enough to recognise the branch
in a list, not a restatement of the issue title.

```
feature/PROJ-123-add-auth-middleware
fix/PROJ-456-null-deref-on-empty-payload
refactor/PROJ-789-simplify-payment-flow
```

Worktrees follow the branch: `.worktrees/<branch-name>/`, unless the repo sets its
own location.

## Pull request titles

The key is mandatory in the title. It is what lets a reader of the merge history,
or an automated changelog, find the intent behind a change.

```
<type>(<KEY>): <description>
```

The `<type>` vocabulary and its semver meaning come from the `commit-standards`
skill in `dev-standards` — this skill only adds the rule that the scope is the
issue key when one exists.

```
feat(PROJ-123): add org hierarchy endpoint
fix(PROJ-456): route gateway traffic through the stable alias
chore(PROJ-789): bump runtime dependencies
```

## When the branch has no key

It happens: a branch created in a hurry, or one inherited from elsewhere.

1. Ask for the issue key. Do not open the pull request without one.
2. Once you have it, either rename the branch (if nothing has been pushed and no
   one else has it checked out) or put the key in the title and reference it in
   the pull request body.
3. Renaming a shared branch is worse than a mismatched name. Prefer the title fix.

Never omit the key on the grounds that "the description explains it". A key is
queryable; prose is not.

## Deriving, not remembering

Given `feature/PROJ-123-add-auth-middleware`, everything else follows:

| Artefact | Derived value |
| --- | --- |
| Commit scope | `PROJ-123` |
| Pull request title | `feat(PROJ-123): <description>` |
| Tracker comment | Links the pull request to `PROJ-123` |
| Search for this work later | One query on the key |

That last row is the payoff. A year on, "why is this code here" is answered by
grepping one key across the history and the tracker — provided the key was put
in both.
