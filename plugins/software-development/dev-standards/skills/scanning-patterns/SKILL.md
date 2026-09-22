---
name: scanning-patterns
license: MIT
description: How to search a codebase efficiently — scope a scan to the changed files, prefer a real linter over a hand-written grep, and validate any pattern you do write against both a matching and a non-matching fixture. Use when scanning a diff for issues, writing a detection pattern, or deciding whether a grep sweep is worth running at all.
---

# Scanning Patterns

Two rules do most of the work here:

1. **If a tool already checks it, run the tool.** A linter gives a rule id, a location and
   a documentation link per finding. A grep gives a line. Re-grepping for something a
   linter already covers duplicates the work and invites disagreement with the tool's own
   verdict.
2. **Scope to the changed files.** A whole-tree sweep returns mostly pre-existing code the
   change never touched. That is noise proportional to repo size, which is the opposite of
   a review signal. See `file-scope-rules`.

## Prefer the tool

| Class of finding | Run this instead of grepping |
| --- | --- |
| Credentials, private keys, connection strings | A dedicated secret scanner — two of them, since their rulesets disagree at the edges |
| Python injection, `subprocess(shell=True)`, bare `except`, hardcoded passwords | `bandit`, `ruff`, `mypy`, `pylint` |
| Shell portability, unquoted expansions, non-POSIX constructs | `shellcheck` |
| Infrastructure-as-code misconfiguration and policy | `terraform fmt`, `tflint`, and a policy scanner |
| TypeScript/JavaScript correctness and style | `tsc --noEmit`, `eslint` |
| Consumers of a changed export | The language server or a build-graph query |

Reach for a hand-written pattern only for what none of the installed tools covers, and
say which tool is missing when you do — "no TS linter is installed here" is useful review
context; a silent fallback to grep is not.

## When you do grep

Scope with an explicit changed-file list. Never `grep -r .`.

```bash
# Build the list once, from the diff, and reuse it.
mapfile -t CHANGED < <(git diff --name-only --diff-filter=ACMR origin/main...HEAD)

# Example: XSS sinks, only if no JS/TS linter is available.
grep -nE 'dangerouslySetInnerHTML|v-html=|\.innerHTML[[:space:]]*=|document\.write\(' "${CHANGED[@]}"

# Example: eval on a JS/TS path.
grep -nE '\beval\(' "${CHANGED[@]}"

# Example: unpaginated collection reads.
grep -nE '\.find\(\)|\.findAll\(\)|\.select\(\)' "${CHANGED[@]}"
```

Filter the list by extension before passing it to a language-specific pattern, and handle
the empty case — `grep` with no file arguments reads stdin and hangs.

## Validate every pattern you write

A pattern that has never been shown to fire is worse than no pattern, because it reads as
coverage. Before keeping one, prove both halves:

- It matches a fixture that **should** match.
- It stays silent on a fixture that **should not**.

Three failure modes account for most broken patterns in practice:

- **`\n` inside an ERE.** `grep` matches within a single line. A pattern like
  `"async def.*:\n.*\bopen\("` can never fire on the multi-line construct it was written
  for. Use a real parser, or `grep -A` plus a second filter.
- **PCRE syntax in `grep -E`.** Lookahead and lookbehind (`(?!...)`, `(?<=...)`) are not
  POSIX ERE. GNU grep silently misinterprets some of it; BSD grep on macOS errors out with
  `repetition-operator operand invalid` and exit 2 — so the pattern never ran at all. Use
  `grep -P` where available, or `rg`, and check the exit code.
- **Patterns that match ordinary code.** `\.(all|filter)\(\)` across every Python file
  flags routine ORM use. If a pattern's hit rate on healthy code is not near zero, it is
  not a detector.

Check the exit code, not just the output: `grep` returns 0 on match, 1 on no match, and
**2 on error**. Treating 2 as "clean" is how a broken pattern reports success forever.

## Search tool choice

| Tool | Use it for |
| --- | --- |
| `rg` (ripgrep) | Default. Fast, respects ignore files, PCRE via `-P`, sane multiline via `-U`. |
| `grep` | Portable fallback. Assume BSD semantics unless you have checked. |
| `git grep` | Searching tracked content only, or a specific revision. |
| `find` | Locating files by name or type — then feed the list to a content search. |

Narrow before you widen: file-type filter, then directory, then pattern. Starting from a
broad pattern over the whole tree and filtering the output afterwards wastes the search and
buries the signal.
