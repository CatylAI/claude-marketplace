---
name: review-scan
description: "Run the deterministic, ZERO-TOKEN detection pass over a git diff: ruff, bandit, mypy, pylint, shellcheck, gitleaks and trivy, plus dependency-pinning, commented-out-code and changed-symbol-consumer checks, over only the files a branch changed — then normalise every tool's JSON into one AgentContract at .code-review/SCAN.json with findings hunk-filtered to changed lines. Also writes SCAN-SUMMARY.md with counts by tool and severity and an explicit SKIPPED list, so a missing linter is visible rather than silently absent. Use before any semantic review pass to catch mechanically-detectable defects without spending tokens on them, standalone to see what the linters say about a branch, or as a CI job whose artifact a later review consumes. NOT the whole review — it cannot judge business logic, authorization or design, which is the semantic pass. NOT a gate: it reports, it does not enforce."
license: MIT
user-invocable: true
argument-hint: "[--base <ref>] [--detectors a,b]"
allowed-tools: Bash(git:*), Bash(python3:*), Bash(bash:*), Read, Grep, Glob
---

# review-scan — deterministic detection, zero tokens

Static analysis finds mechanically-detectable defects better and cheaper than an LLM reading files.
`bandit` finds the hardcoded password, the `subprocess(shell=True)` and the partial executable path;
`ruff` finds the bare `except`; `gitleaks` and `trivy` find the committed key. Each comes back with a
rule ID, a severity and a doc URL. Paying several agents at `maxTurns: 80` to hand-grep for the same
patterns costs real money and finds less.

So this skill does the detection, and Claude does the part no linter can: business logic,
authorization, tenancy, concurrency, and design.

## Run it

```bash
# The script is the whole interface. Same invocation locally and in CI — deliberately.
"$CLAUDE_PLUGIN_ROOT/pipeline/review-scan.sh" --base origin/main
```

| Flag | Default | Notes |
| --- | --- | --- |
| `--base <ref>` | **required** | merge base. `origin/main` locally, a CI-supplied base SHA in CI |
| `--source <ref>` | `HEAD` | the branch under review |
| `--out <dir>` | `.code-review` | shares the workspace the rest of the review pipeline uses |
| `--detectors a,b` | chosen from the changed files | `python`, `shell`, `terraform`, `deps`, `comments`, `secrets`, `impact` |
| `--max-findings N` | `150` | truncates lowest-severity-first, and records that it did |
| `--fail-under N` | from `pyproject.toml` / `setup.cfg` / `.coveragerc` | coverage gate |
| `--quiet` | off | suppress progress on stderr |

Outputs, all under `--out`:

| File | Contents |
| --- | --- |
| `SCAN.json` | the `AgentContract` — **this is what a reviewer reads** |
| `SCAN.raw.json` | the same before diff-scoping; useful when a finding you expected is missing |
| `SCAN-SUMMARY.md` | counts by tool and severity, and the `SKIPPED:` list |
| `raw/<tool>.json` | each tool's native output, kept for debugging and as a CI artifact |
| `raw/<tool>.skipped` | one line saying why a tool did not run |

**Exit status is 0 whenever the scan completed, whatever it found.** Findings are reported, not
enforced. A scan that failed a pipeline because a linter is missing from the runner image would be
worse than no scan at all.

## Reading the output

Three properties of `SCAN.json` matter when you triage it:

1. **Findings are on changed lines.** Everything is piped through
   `pipeline/filter-carried-findings.py`, which intersects each cited line against the new-side `@@`
   hunks of the real diff, so a repo's pre-existing lint debt does not reach you. Check
   `scan_meta.diff_scoped`; if it is `false`, the filter did not run and you are looking at
   unfiltered debt.
2. **`SKIPPED` is as important as the findings.** A scan with four of six tools present looks exactly
   like a clean scan unless the gaps are stated. `scan_meta.tools_skipped` and the summary's
   "Coverage gaps" section name every one, with a reason. A verdict should say "scanned with 4 of 6
   detectors", never imply the whole diff was covered.
3. **Severity comes from the tool, and some tools cannot supply it.** A tool reporting
   `severity: null` has its findings defaulted to `MINOR` regardless of real risk — recorded in
   `scan_meta.notes`. Judge those findings on the rule, not the severity.

## What each detector covers

| Detector | Tools | Notes |
| --- | --- | --- |
| `python` | ruff, bandit, mypy, pylint | ingests `raw/pytest.json` + `raw/coverage.json` if CI drops them in; does not run the suite itself |
| `shell` | shellcheck | `.sh`/`.bash`/`.zsh` plus extensionless files whose first line is a shell shebang |
| `terraform` | terraform fmt, tflint, checkov, tfsec | `.tf`/`.tfvars`/`.hcl`. `terraform validate` is never run: it needs `init`, and the scan authenticates nowhere |
| `secrets` | gitleaks, trivy | always runs when anything changed; both always `--redact` |
| `deps` | its own | unpinned dependencies in `package.json`, `requirements*.txt`, `pyproject.toml`, `Dockerfile`, `.github/workflows/*`, `.pre-commit-config.yaml` — an action on a tag or a `:latest` base is MAJOR, a caret range beside a lock file is a NIT |
| `comments` | its own | blocks of commented-out code, and `TODO`/`FIXME`/`XXX` with no issue reference — both NIT, both a shortlist for a human |
| `impact` | git grep | removed/renamed/signature-changed symbols → consumers outside the diff, as NIT |

A detector named in `--detectors` that is not bundled is recorded as an explicit skip and the scan
continues. **TS/JS is thin**: neither `semgrep` nor `eslint` is assumed installed and `tsc` needs the
project's `node_modules`, so TS/JS files get `secrets` + `impact` only. The scan records that as a
skip rather than pretending the stack was covered.

## Feeding it test and coverage results

`detectors/python.sh` ingests two files if they are already on disk; it never runs the suite itself.
Mind the two shapes:

- `raw/coverage.json` is coverage.py's own `{totals: {percent_covered}, files: {…}}`, which
  `--cov-report=json` produces directly.
- `raw/pytest.json` is **this scanner's own summary**, `{failed: [{nodeid, file, line, message}],
  rc: int}` — not any plugin's schema. Derive it from a JUnit XML report with the standard library;
  no pytest plugin is needed.

Emit both from the job that already has the project environment and the services, and publish them
as artifacts a later review consumes.

## Where the real findings come from

Measured across benchmark diffs in repos that already ran the same linters at pre-commit time, the
diff-scoped yield of this scan was near zero — because those gates had already passed and their
findings were already fixed. That does not refute the premise that a linter beats an LLM at
grep-shaped detection; it shows the saving was banked earlier. The division that follows:

| Layer | Owns | Why |
| --- | --- | --- |
| pre-commit | ruff, pylint, shellcheck, gitleaks, trivy | already installed, already blocking, runs before the commit exists |
| CI | pytest + coverage JSON, published as artifacts | needs the project env and services; neither pre-commit nor an agent can do it |
| `review-scan.sh` | mypy, impact, plus ingest of CI's artifacts | the detectors not enforced upstream |
| `review-semantic` | the judgement lenses | where essentially all the real findings come from |
