---
name: commit-standards
license: MIT
description: Conventional Commits format, semver impact per type, and scope rules for commit subjects. Use whenever you are authoring a commit message, writing a PR title that feeds a changelog, or reviewing whether a commit message is well-formed.
---

# Commit Standards

## Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

- **Subject** — imperative mood ("add", not "added"/"adds"), no trailing period,
  under ~72 characters, lowercase after the colon.
- **Body** — optional. Explain *why*, not *what*; the diff already shows what.
  Wrap at ~72 columns, blank line after the subject.
- **Footer** — optional. Breaking-change notices, issue references, trailers.

## Types and semver impact

| Type | Semver | Example |
| --- | --- | --- |
| `feat` | **MINOR** | `feat(auth): add OAuth2 login` |
| `fix` | PATCH | `fix(api): handle null response` |
| `docs` | PATCH | `docs(readme): update install instructions` |
| `refactor` | PATCH | `refactor(utils): simplify date parsing` |
| `perf` | PATCH | `perf(query): add index for user lookup` |
| `test` | PATCH | `test(auth): cover login edge cases` |
| `ci` | PATCH | `ci: run typecheck on pull requests` |
| `build` | PATCH | `build: update bundler config` |
| `chore` | PATCH | `chore: update dependencies` |
| `style` | PATCH | `style(ui): fix button alignment` |
| `revert` | PATCH | `revert: revert "feat(auth): add OAuth2 login"` |

A breaking change is marked either with `!` after the scope or with a
`BREAKING CHANGE:` footer, and is **MAJOR** regardless of type.

## Scope convention

- On an issue-tracked branch, use the issue ID: `feat(PROJ-123): add search filter`.
- With no tracker context, use the component or package: `fix(api): handle null response`.
- Omit the scope when the change is repo-wide: `chore: update dependencies`.

Pick one scope vocabulary per repo and stay in it. Mixing issue IDs and component
names arbitrarily makes the history unfilterable.

## Examples

Feature on an issue-tracked branch:

```
feat(PROJ-123): add search filter for the user list
```

Bug fix scoped to a component, with a reason in the body:

```
fix(api): handle null user response gracefully

The upstream directory returns 204 with an empty body for suspended
accounts; we were dereferencing the parsed payload unconditionally.
```

Breaking change:

```
feat(api)!: remove deprecated v1 endpoints

BREAKING CHANGE: /api/v1/* is removed. Migrate callers to /api/v2/*.
```

## Attribution

If the project requires a co-author trailer for assistant-written commits, add it in
the footer in the form the project specifies, and apply it consistently. Check
`CONTRIBUTING.md` or the repo's agent instructions rather than assuming.

## Enforcement

Most repos enforce this with a `commit-msg` hook (for example `commitlint` or
`conventional-pre-commit`). If the repo has one, run it locally before pushing —
a rejected message after a long rebase is expensive to fix.
