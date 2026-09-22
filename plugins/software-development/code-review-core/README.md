# code-review-core

Forge-neutral code review. Deterministic detectors find issues, bounded agents judge them, a
validation pass owns the verdict.

The whole pipeline runs on a plain `git diff`. It makes no API call to any code-hosting provider,
issue tracker, or chat service, and it posts nothing anywhere. Transport is a separate concern and
belongs in a separate plugin.

## When to use it

- Reviewing a branch against its merge base, locally or in CI, with no credentials of any kind.
- Getting the deterministic linter pass over only the files a branch changed, without spending
  tokens on it.
- Building a review gate whose verdict a script can read: `.code-review/VALIDATED.json`.

## When not to use it

- You need findings posted to a pull request or merge request. That is a transport plugin's job;
  this one only writes files.
- You want a chat-style "review my code" conversation. This is a pipeline with a machine-readable
  contract, not a conversation.

## Surfaces

**This plugin is Claude Code only.** It is the one place in this marketplace where that is
true of the whole plugin rather than a part of it, and it is worth being explicit about why.

The pipeline is shell scripts over a `git` checkout, and the judgement stage is five subagents.
Cowork (Claude Code on the web) has neither a shell nor a checkout, and does not run subagents.
There is no degraded mode to fall back to: without `git diff` there is nothing to detect, and
without the agents there is no verdict. A review that silently produced no findings because it
could not run would be worse than no review, so the plugin does not pretend to offer one.

The `review-scan` skill and `SKILL.md` remain readable on the web as documentation.

## Layout

```
code-review-core/
├── SKILL.md                         the pipeline contract and how the stages compose
├── agents/
│   ├── review-semantic.md           business logic, authz, concurrency, error paths
│   ├── review-testing.md            test quality — gated
│   ├── review-architect.md          design and DRY — gated
│   ├── review-authoring-conformance.md  Claude Code authoring conformance — gated
│   └── review-validator.md          re-reads every cited line; owns the verdict
├── pipeline/
│   ├── review-scan.sh               the zero-token detection pass
│   ├── prepare-context.sh           runs the scan, bounds the diff, decides the gates
│   ├── detectors/                   one script per tool family, dispatched by review-scan.sh
│   │   ├── python.sh · shell.sh · terraform.sh · secrets.sh · impact.sh
│   │   ├── deps.sh · comments.sh    dependency pinning, and the mechanical half of comment quality
│   │   ├── detectors.test.sh        the shared detector contract, over every detector on disk
│   │   └── terraform.test.sh · deps.test.sh · comments.test.sh   each detector's own arms
│   ├── normalize.py                 folds every tool's output into one AgentContract
│   ├── filter-carried-findings.py   intersects each cited line against the diff's @@ hunks
│   ├── contract.py                  the finding contract as executable rules, not prose
│   ├── testpaths.py                 the one test-path regex both scripts share
│   ├── _lib.sh                      shared shell helpers
│   ├── *.test.sh                    one companion suite per script; see Tests below
│   └── schemas/                     generated from contract.py; a build artifact, never hand-edited
└── skills/
    └── review-scan/                 user-invocable wrapper for the detection pass
```

## Quick start

```bash
PIPE="$CLAUDE_PLUGIN_ROOT/pipeline"

# Detection only — reports, never enforces, exits 0 whatever it finds
"$PIPE/review-scan.sh" --base origin/main

# Detection plus the bounded context the judgement agents read
"$PIPE/prepare-context.sh" --base origin/main
```

Everything lands in `.code-review/`, which gets its own `.gitignore` (`*`) on creation so the
artifacts cannot be committed by accident. Delete that file if you want them committable.

## Detectors

| Detector | Tools | Notes |
| --- | --- | --- |
| `python` | ruff, bandit, mypy, pylint | also ingests `raw/pytest.json` + `raw/coverage.json` if CI drops them in; never runs the suite itself |
| `shell` | shellcheck | `.sh`/`.bash`/`.zsh` plus extensionless files with a shell shebang |
| `terraform` | terraform fmt, tflint, checkov, tfsec | `.tf`/`.tfvars`/`.hcl`; `terraform validate` is never run — it needs `init`, and a review scan authenticates nowhere |
| `secrets` | gitleaks, trivy | always runs when anything changed; both always `--redact` |
| `deps` | its own | unpinned dependencies in `package.json`, `requirements*.txt`, `pyproject.toml`, `Dockerfile`, `.github/workflows/*`, `.pre-commit-config.yaml`; selected by path shape, not extension |
| `comments` | its own | blocks of commented-out code, and `TODO`/`FIXME`/`XXX` with no tracked reference — both NIT |
| `impact` | git grep | removed/renamed/signature-changed symbols → consumers outside the diff, as NIT |

`deps` is the one detector with a real supply-chain argument rather than a reproducibility one. An
action pinned to a tag, or a `FROM <image>:latest`, is MAJOR: a tag is a mutable pointer in somebody
else's repository, so the next run executes code nobody reviewed, in a job holding this repo's
secrets. Its Actions rule is written to agree clause for clause with the `actions-authoring` skill in
`github-workflow`, exemptions included. A caret range on a devDependency, or any caret range beside a
lock file, is a NIT — the tiers are spread deliberately, because a detector whose findings all arrive
at one severity is one readers learn to skip.

`comments` covers only what is decidable from the text. "Is this comment accurate?" is judgement and
lives in `dev-standards`' `code-comments` skill; "is this three lines of commented-out code" does not,
so it is decided here for free on every change. Where it overlaps a linter it supersedes it rather
than doubling up: pylint's `W0511` (`fixme`) flags every marker including one that correctly carries
an issue reference, so `normalize.py` suppresses `W0511` — but only on a run where the `comments`
detector actually produced output, because a `--detectors python` scan with the rule dropped and
nothing in its place would be a silent loss of coverage. The suppression is counted and printed in
`SCAN-SUMMARY.md` like every other.

Every tool that could not run is recorded as an explicit skip in `SCAN-SUMMARY.md` rather than
silently omitted — a missing binary, an unparseable output, a diff with none of that detector's file
types. A scan with four of nine tools present looks exactly like a clean scan unless the gaps are
stated, so they always are, and detectors always exit 0 so a gap can never fail a review.

TS/JS coverage is thin on purpose: neither `semgrep` nor `eslint` is assumed present and `tsc` needs
the project's `node_modules`, so TS/JS files get `secrets` + `impact` only — and the scan says so.

## Design decisions worth not undoing

- **Secret findings never carry the source line as evidence.** For every other tool `evidence` is the
  cited line read off disk. For a secret finding that line *is* the credential, and copying it into
  `SCAN.json` puts a live secret into a file an agent reads and may quote. Secret findings get a
  fixed redaction notice instead, and the detectors pass `--redact` so `raw/` is clean too.
- **`gitleaks` is invoked one file per run.** Handing it several paths makes it ignore all but the
  first and scan that path's whole tree — measured as an 8.16 MB scan where the target was 99 bytes.
- **Range findings are emitted as enumerated lines.** A tool reporting a resource block as
  `[4, 11]` would survive the hunk filter only on lines 4 and 11; spans up to 30 lines are written
  out in full so a change on line 8 is not dropped.
- **Newly added symbols get no impact finding.** Nothing outside the diff can reference a name that
  did not exist before it.
- **Tools are invoked directly, not through `pre-commit`.** `pre-commit` would give many hooks free
  but emits text, which puts an LLM back in the parsing loop — the exact cost this removes.
- **checkov is invoked once per changed IaC directory.** Measured against checkov 3.2.x, a single
  run carrying several `-d` flags reports *every* finding under the first directory's path, so a
  second module's violations arrive attributed to a file that does not contain them. checkov and
  tfsec are directory-oriented in the first place because a lone `.tf` file rarely parses without
  the siblings declaring its variables.

## Tests

Every pipeline script has a `.test.sh` companion. They are plain shell, take no arguments, and each
builds its own throwaway git repo under `$TMPDIR` that a `trap` removes on exit — nothing outside
that directory is touched, no network is used, and no fixture is committed.

```bash
PIPE="$CLAUDE_PLUGIN_ROOT/pipeline"

bash "$PIPE/review-scan.test.sh"              # the scan end to end, plus normalize.py's units
bash "$PIPE/prepare-context.test.sh"          # CONTEXT.json, DIFF.md budgeting, the four gates
bash "$PIPE/_lib.test.sh"                     # the --out safety guard, and that it still refuses
bash "$PIPE/contract.test.sh"                 # schemas/ has not drifted from contract.py
bash "$PIPE/detectors/detectors.test.sh"      # the detector contract, over every detector on disk
bash "$PIPE/detectors/terraform.test.sh"      # the IaC detector's own arms
bash "$PIPE/detectors/deps.test.sh"           # the pinning rules, and the pinned-is-silent half
bash "$PIPE/detectors/comments.test.sh"       # the comment rules, and the prose-is-silent half
```

Each suite also runs under `zsh`, which is half of what "portable bash 3.2+ / zsh" is asserting.

A test that needs a binary this machine does not have reports itself as **skipped**, never as a
pass — the same degradation the scanner is built around, for the same reason: a green run that
quietly tested nothing is worse than a red one.

The house style is **plant a defect, assert a non-zero exit**. A gate nobody has watched fail is an
assumption, not a check, so the suites that guard a refusal also prove they can refuse:
`_lib.test.sh` asserts the `--out` guard still rejects each typo shape *and* that no `*` fence was
written on the way out; `contract.test.sh` perturbs a copy of the generated schema four ways and
asserts the drift gate catches all four; `detectors.test.sh` runs every detector against a PATH with
the analysis tools deliberately removed, so the missing-binary branch is genuinely taken rather than
assumed.

## Dependencies

`dev-standards`, for the `code-review-standards`, `file-scope-rules` and `agent-contracts` skills the
agents inject by name.

## License

MIT.
