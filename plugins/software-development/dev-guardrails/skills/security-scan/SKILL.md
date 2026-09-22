---
name: security-scan
license: MIT
description: Point-in-time security sweep of one repository — runs bandit, gitleaks, trivy and checkov over the whole tree, then reads code for the authorization, data-exposure and injection gaps no scanner can decide. Produces findings grouped by severity with file:line citations and what to rotate or fix. Use when auditing a repo, before a release, when inheriting an unfamiliar codebase, or when someone asks "is this safe to ship". Not for reviewing a single pull request — a diff-scoped review is a different job.
argument-hint: "[path — defaults to the current directory]"
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(find:*), Bash(bandit:*), Bash(gitleaks:*), Bash(trivy:*), Bash(checkov:*), Bash(mktemp:*), Bash(command:*), Bash(echo:*)
---

# Security Scan

A whole-tree audit of one repository. Scanners first, judgement second — in that order, and the
order is the point.

## Why the scanners run first

`bandit`, `gitleaks`, `trivy` and `checkov` find the pattern-shaped half of this work better than
reading the code does, and they say more about each finding than a reader can: a rule id, a
severity, a confidence, and a link to the explanation. Reading every file by hand to look for
`shell=True` spends a large amount of context re-deriving what a `grep`-shaped tool already knows.

What the scanners cannot do is reason about *this* codebase: whether a route's permission check is
the right one, whether a query is scoped to the tenant as well as the id, whether a reported CVE is
reachable from any code path that actually runs. That is the second pass, and bounding it is what
keeps this skill finishing.

## Scope, and how it differs from a pull-request review

This is a sweep of the **whole tree**, so pre-existing debt is the point rather than noise. Do not
filter findings by diff. A pull-request review does the opposite — it scopes to changed lines
precisely so a reviewer is not handed the repository's entire backlog — and if that is what is
wanted, this is the wrong tool.

## Step 1 — Scope the scan

Use the path that was passed, or the current working directory.

```bash
TARGET="${1:-.}"
find "$TARGET" -type f \
  \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
     -o -name '*.go' -o -name '*.rb' -o -name '*.tf' \) \
  | grep -vE '(node_modules|__pycache__|\.git/|dist/|build/|vendor/|\.terraform)' \
  | head -200
```

Note roughly how many files there are and what the tree is made of. That number goes in the
summary, and it is what makes "no findings" mean something.

## Step 2 — Run the scanners

Each tool is optional. A missing binary is recorded and skipped, never fatal: a sweep that aborts
because one tool is absent reports nothing about the four that were present.

**A non-zero exit means "found something", not "failed".** Treating a scanner's exit code as an
error is the single most common way these tools end up wrapped in `|| true` and silently disabled.

```bash
TARGET="${1:-.}"
OUT="$(mktemp -d)"

if command -v bandit >/dev/null; then
  bandit -r "$TARGET" -f json -q > "$OUT/bandit.json" 2>/dev/null
else echo "SKIPPED: bandit (pip install bandit)"; fi

if command -v gitleaks >/dev/null; then
  gitleaks detect --source "$TARGET" --report-format json \
    --report-path "$OUT/gitleaks.json" --redact >/dev/null 2>&1
else echo "SKIPPED: gitleaks"; fi

if command -v trivy >/dev/null; then
  trivy fs --scanners vuln,secret,misconfig --format json \
    -o "$OUT/trivy.json" "$TARGET" >/dev/null 2>&1
else echo "SKIPPED: trivy"; fi

if command -v checkov >/dev/null; then
  checkov -d "$TARGET" --output json --compact > "$OUT/checkov.json" 2>/dev/null
else echo "SKIPPED: checkov (pip install checkov)"; fi

echo "raw output in $OUT"
```

What each one covers:

| Tool | Finds |
| --- | --- |
| `bandit` | Python: injection, weak crypto, unsafe deserialization, `shell=True` |
| `gitleaks` | Committed credentials, across history as well as the working tree |
| `trivy` | Dependency CVEs, secrets, infrastructure misconfiguration |
| `checkov` | Terraform / CloudFormation / Kubernetes policy violations |

Read the JSON files that exist and triage them yourself.

**Never quote the matched line for a secret finding.** `gitleaks` redacts on purpose, and `trivy`'s
secret findings must be treated identically — for a secret, the cited line *is* the credential, and
pasting it into a report moves the leak somewhere new. Cite `file:line` and the rule, and say what
needs rotating.

## Step 3 — Read what no scanner can decide

Then cover, by reading code, only the four things a pattern cannot settle:

- **Authorization gaps.** A route or handler with no permission check. A query filtered by resource
  id but not by tenant or organization. A check that fails open — catches an error and proceeds.
- **Sensitive data exposure.** Personal data in log lines, credentials in error messages or stack
  traces, data crossing a classification boundary.
- **Injection the tools missed.** Dynamic SQL or command construction they did not flag — most
  often because a helper function hides the concatenation from the pattern.
- **Dependency risk in context.** `trivy` reports the CVE; you decide whether the vulnerable code
  path is reachable from anything this repository actually runs.

**Bound this pass: read at most 15 files.** Choose them from the scanner hits and from whatever the
Step 1 listing shows to be authentication, authorization or entry-point code. Name which files you
read — an unbounded "I looked at the code" pass is the part of a security review that silently does
not happen.

## Step 4 — Report

Group by severity and lead with the count, so an empty result is legible as a result:

```
N files scanned · B blockers · M majors · m minors
Scanners run: bandit, gitleaks, trivy    Skipped: checkov (not installed)
Files read in the judgement pass: 9 (listed below)
```

Then one entry per finding:

- **BLOCKER** — exploitable now, or a live credential is exposed. Say what to rotate.
- **MAJOR** — a real weakness needing a deliberate fix.
- **MINOR** — hardening, defence in depth, or a latent risk.

Each entry carries `file:line`, the rule id where a scanner produced it, what an attacker gets, and
the fix. If a tool was skipped, say so in the summary — the reader needs to know which half of the
sweep did not run, because "no findings" from a tool that never executed looks exactly like a pass.
