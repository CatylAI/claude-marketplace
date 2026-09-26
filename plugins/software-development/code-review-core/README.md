# code-review-core

Forge-neutral code review. Deterministic detectors find issues, bounded agents judge them, a
validation pass owns the verdict.

The whole pipeline runs on a plain `git diff`. It makes no API call to any code-hosting provider,
issue tracker, or chat service, and it posts nothing anywhere. Transport is a separate concern and
belongs in a separate plugin.

## Install

**Claude Code** (terminal, desktop app, VS Code):

```
/plugin marketplace add CatylAI/claude-marketplace
/plugin install code-review-core@catylai
```

**Cowork and claude.ai:** `/plugin` is not available there. Enable this plugin for your
claude.ai account and it loads automatically as a synced plugin. Only the skills load
there, and the pipeline does not run (see Surfaces).

## When to use it

- Reviewing a branch against its merge base, locally or in CI, with no credentials of any kind.
- Running the linter pass over only the files a branch changed, without spending tokens on it.
- Building a review gate whose verdict a script can read: `.code-review/VALIDATED.json`.
- Reviewing on GitLab, or anywhere the result has to reach a forge through a separate transport.

## When not to use it

- For a quick, conversational review of a diff, use the built-in `/code-review`. It is cheaper and
  can post PR comments itself. This plugin is for when you need the deterministic scan, the gated
  agents, and a verdict file.
- To post findings to a pull or merge request, use a transport (see Consumers below). This plugin
  only writes files.

## Surfaces

**Claude Code only: CLI, desktop, and Claude Code on the web.** The pipeline is shell scripts over
a git checkout, and the judgement stage is subagents. It does not work in Cowork, which has no
checkout to diff.

On the web, the scripts run, but most linters are usually not installed there. Each missing tool is
recorded as a skip in `SCAN-SUMMARY.md` rather than hidden. Without a checkout, both skills say so
and point to `/code-review` on a pasted diff. They do not imitate a result.

## Running it

| Entry point | What it does |
| --- | --- |
| `/code-review-core:review [base-ref] [--effort low\|medium\|high]` | the whole pipeline, ending in `VALIDATED.json` |
| `/code-review-core:review-scan [base-ref]` | the detection pass only, ending in `SCAN.json` |

With no base ref, both use `origin/HEAD`, then `origin/main`, then `origin/master`. In CI, call the
scripts directly:

```bash
PIPE="$CLAUDE_PLUGIN_ROOT/pipeline"

# Detection only: reports, never enforces, exits 0 whatever it finds
bash "$PIPE/review-scan.sh" --base origin/main

# Detection plus the bounded context the judgement agents read
bash "$PIPE/prepare-context.sh" --base origin/main
```

Everything lands in `.code-review/`, which gets its own `.gitignore` (`*`) on creation so the
artifacts cannot be committed by accident. Delete that file if you want them committable.

## The shape of a review

The stages communicate only through files in `.code-review/`, so each one can run and be tested
on its own.

```
1. DETECT    pipeline/review-scan.sh
             11 linters and scanners, plus dependency pinning, commented-out code,
             IaC policy rules, changed-symbol impact
             -> SCAN.json, SCAN-SUMMARY.md          (no tokens; reports, never enforces)

2. BOUND     pipeline/prepare-context.sh
             runs the scan, caps the diff, decides which gated agents spawn
             -> CONTEXT.json, DIFF.md

3. JUDGE     review-semantic                 always                 -> SEMANTIC.json
             review-testing                  testing.spawn          -> TESTING.json
             review-architect                architect.spawn        -> ARCHITECTURE.json
             review-authoring-conformance    claude_config.spawn    -> CLAUDE_CONFIG.json
             (in parallel)

4. VALIDATE  review-validator                re-reads every cited line -> VALIDATOR-DECISIONS.json

5. FINALIZE  pipeline/contract.py finalize   deterministic merge   -> VALIDATED.json, VALIDATED.md
```

The `review` skill runs all five in order. If a stage fails, the review ends as `INCOMPLETE` with the
reason stated, never as a clean result.

### Write guard

The judge and validator agents need `Write` for their artifacts, and agent frontmatter cannot scope
it to a path. `hooks/hooks.json` registers a `PreToolUse` hook on `Write|Edit|NotebookEdit` that runs
`hooks/guard-review-writes.py` (python3, standard library only). When the calling agent's
`agent_type` starts with `code-review-core:review-` and the target resolves (after `..` and symlinks)
outside a `.code-review/` directory, it denies the call and tells the agent where to write instead.
Every other call, including the main session and other plugins' agents, passes through untouched,
so the hook never affects normal work. If the hook input cannot be parsed, it allows the call and
prints a note on stderr: blocking every write in every session on a malformed input would do more
harm than the prompt-level limit it backs up. A custom `--out` not named `.code-review` is outside
the guard's allowance, so the `review` skill always uses the default.

### Why it is built this way

- **Deterministic first.** A linter beats a model at grep-shaped detection and costs nothing per run,
  so agent budget goes only to business logic, authorization, concurrency, error paths, test adequacy
  and design.
- **Bounded context.** `prepare-context.sh` caps the diff and records what it left out. An agent
  reading an unbounded repository spends its turns on orientation.
- **Deterministic gates, not self-assessment.** Whether the architect, testing or
  authoring-conformance agent runs is decided by `prepare-context.sh`, with a recorded reason, before
  the agent exists.
- **One owner of the verdict.** Agents write findings. The validator records its judgements, and the
  deterministic `finalize` step alone writes the verdict. Findings that nobody re-read are proposals,
  not results.

### Where the findings come from

In repos that already run the same linters at pre-commit, the scan's diff-scoped yield is near zero,
because those gates already passed. The saving is real, but it was banked earlier. The layering that
follows:

| Layer | Owns |
| --- | --- |
| pre-commit | ruff, pylint, shellcheck, gitleaks, trivy: already installed and blocking |
| CI | pytest and coverage JSON, published as artifacts the scan ingests |
| `review-scan.sh` | mypy, impact, and whatever is not enforced upstream |
| `review-semantic` | the judgement lenses, where most real findings come from |

## Consumers and contract

`VALIDATED.json` is the only output other plugins read. Its shape is part of this plugin's public
interface.

- **Completion signal.** `.code-review/VALIDATED.json` present and parseable means the run
  finished. An unfinished run leaves an `INCOMPLETE` document or none at all, never a clean one.
- **Schema.** Findings and documents are defined in `pipeline/contract.py`, generated into
  `pipeline/schemas/agent-contract.schema.json`, and documented for agents in
  `dev-standards:agent-contracts`.
- **Verdict.** One of `APPROVE`, `REQUEST_CHANGES` or `INCOMPLETE`, computed by `rollup_verdict` in
  `pipeline/contract.py`.
- **Finding axes.** `severity`, `in_diff` and `confidence` are independent; what each value means
  is owned by `dev-standards:code-review-standards`.
- **Blocking floor.** `--floor` on finalize, else `CODE_REVIEW_BLOCKING_FLOOR`, else `MINOR`. The
  floor used is recorded in `VALIDATED.json`.
- **Finding marker.** Transports tag every posted comment with a fingerprint of the finding's path
  and normalised title (`<!-- code-review-core:fp2:<path>:<title> -->`, grammar in
  `github-workflow:review-transport`), not with its id: `finalize` renumbers ids on every run, so an
  id cannot tell a re-run which findings are already posted.

Current consumers:

| Plugin | Skill | Does |
| --- | --- | --- |
| `github-workflow` | `github-workflow:review-transport` | posts one GitHub PR review; the event follows the verdict |
| `gitlab-workflow` | `gitlab-workflow:review-transport` | posts inline MR discussions and a summary note |
| `terraform-aws` | `terraform-aws:terraform-review` | relies on the `terraform` detector and does not repeat its checks |

## Detectors

| Detector | Tools | Notes |
| --- | --- | --- |
| `python` | ruff, bandit, mypy, pylint | also ingests `raw/pytest.json` + `raw/coverage.json` if CI drops them in; never runs the suite itself |
| `shell` | shellcheck | `.sh`/`.bash`/`.zsh` plus extensionless files with a shell shebang |
| `terraform` | terraform fmt, tflint, checkov, tfsec | `.tf`/`.tfvars`/`.hcl`; `terraform validate` is never run — it needs `init`, and a review scan authenticates nowhere |
| `secrets` | gitleaks, trivy | always runs when anything changed; gitleaks runs with `--redact`, trivy masks secret values itself |
| `deps` | its own | unpinned dependencies in `package.json`, `requirements*.txt`, `pyproject.toml`, `Dockerfile`, `.github/workflows/*`, `.pre-commit-config.yaml`; selected by path shape, not extension |
| `comments` | its own | blocks of commented-out code, and `TODO`/`FIXME`/`XXX` with no tracked reference — both NIT |
| `iac-policy` | its own | Terraform, CI pipelines, Makefiles, `.sql` migrations: `-target` in automation, `dynamodb_table` locking, a default on `environment`/`account_id`/`vpc_id`, undocumented variables, OIDC trust with no `:sub`, `StringLike` with no wildcard, `iam:PassRole` on `"*"`, non-concurrent `CREATE INDEX` on PostgreSQL. Text rules that under-report; none emits BLOCKER |
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

Eight detectors: four cover 11 external tools, `impact` uses `git grep`, and three (`deps`,
`comments`, `iac-policy`) are built-in checks. Every tool that
could not run is recorded as an explicit skip in `SCAN-SUMMARY.md` rather than silently left out:
a missing binary, an unparseable output, or a diff with none of that detector's file types. A scan
with half its tools missing looks exactly like a clean scan unless the gaps are stated, so they
always are. Detectors always exit 0, so a gap can never fail a review.

TS/JS coverage is thin on purpose: neither `semgrep` nor `eslint` is assumed present and `tsc` needs
the project's `node_modules`, so TS/JS files get `secrets` + `impact` only — and the scan says so.

## Design decisions worth not undoing

- **Secret findings never carry the source line as evidence.** For every other tool `evidence` is the
  cited line read off disk. For a secret finding that line *is* the credential, and copying it into
  `SCAN.json` puts a live secret into a file an agent reads and may quote. Secret findings get a
  fixed redaction notice instead. gitleaks runs with `--redact` and trivy masks matched secrets in its
  own output, so `raw/` is clean too.
- **`gitleaks` is invoked one file per run.** Handing it several paths makes it ignore all but the
  first and scan that path's whole tree — measured as an 8.16 MB scan where the target was 99 bytes.
- **Range findings are emitted as enumerated lines.** A tool reporting a resource block as
  `[4, 11]` would survive the hunk filter only on lines 4 and 11; spans up to 30 lines are written
  out in full so a change on line 8 is not dropped.
- **Newly added symbols get no impact finding.** Nothing outside the diff can reference a name that
  did not exist before it.
- **Tools are invoked directly, not through `pre-commit`.** `pre-commit` would give many hooks free
  but emits text, which puts an LLM back in the parsing loop — the exact cost this removes.
- **checkov is invoked once per changed IaC directory.** When measured (re-check against the current
  checkov release before relying on it), a single run carrying several `-d` flags reports *every* finding under the first directory's path, so a
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
bash "$PIPE/detectors/iac-policy.test.sh"     # the Terraform/IAM/migration rules, and their silent cases
bash "$CLAUDE_PLUGIN_ROOT/hooks/guard-review-writes.test.sh"   # the write guard: deny, allow, other agents, fail-open
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

`dev-standards`, for the skills the agents preload by their namespaced names
(`dev-standards:code-review-standards`, `dev-standards:agent-contracts`, and others). The shared
judge rules live in this plugin's own `judge-protocol` skill, which the agents preload as
`code-review-core:judge-protocol`; it is not user-invocable. The pipeline scripts need none of them.
If a `dev-standards` skill is missing, Claude Code skips the preload with only a debug-log warning:
the agents lose the finding keys, the severity table and the scope rules, and nothing in the
verdict reports it (finalize still repairs or rejects malformed findings). Install `dev-standards` alongside this plugin.

## License

MIT.
