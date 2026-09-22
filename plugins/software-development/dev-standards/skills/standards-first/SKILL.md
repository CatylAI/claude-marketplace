---
name: standards-first
license: MIT
description: Read the project's own standards before writing code, so requirements are caught up front instead of in review. Use at the start of any implementation, refactor or review task, and whenever you are unsure which convention governs the change you are about to make.
---

# Standards-First Protocol

Work that starts from memory instead of from the project's written standards gets
rewritten in review. Spend the first few minutes locating the governing document.

## Where standards usually live

Check these in order. Stop at the first one that answers your question.

| Source | Typical location |
| --- | --- |
| Agent instructions | `CLAUDE.md`, `AGENTS.md`, `.claude/` at repo root and in the subtree you are editing |
| Contribution rules | `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md` |
| Architecture decisions | `docs/adr/`, `docs/decisions/`, `rfcs/` |
| Domain guides | `docs/`, a sibling `README.md` in the directory you are changing |
| Machine-enforced rules | linter/formatter config, `.editorconfig`, pre-commit config, CI pipeline definition |
| Existing code | the two or three files nearest your change — the de facto standard when nothing is written down |

Machine-enforced rules win over prose. If the linter and a doc disagree, the linter
is the standard and the doc is stale — say so rather than silently picking one.

## Protocol

1. Name the domains the task touches (testing, security, CI, data modeling, a specific service).
2. Locate the governing document for each. Read it, do not skim the headings.
3. If no standard exists for a domain, apply general best practice and **state the gap
   explicitly** in your summary — an unwritten convention is a decision someone still has to make.
4. Apply the standards throughout. They override your own preferences and the patterns
   you carry in from other projects.
5. If a standard is wrong or blocks the task, raise it as a separate change. Do not
   quietly deviate.

## Failure modes this prevents

- Introducing a second way to do something the repo already has one way to do.
- Writing tests in a layout the test runner does not pick up.
- Choosing a dependency the project has already rejected in an ADR.
- Getting a whole PR rewritten over a convention documented in the file you skipped.
