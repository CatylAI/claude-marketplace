#!/usr/bin/env bash
# review-scan.sh — deterministic, zero-token detection pass for a code review.
#
#   review-scan.sh [--base <ref>] [--source <ref>] [--out .code-review] [--detectors a,b] [...]
#
#   local : review-scan.sh                      (base: origin/HEAD, else origin/main, else origin/master)
#   CI    : review-scan.sh --base "$DIFF_BASE_SHA"
#
# THE SAME SCRIPT runs in both places — that is the point. A CI job that used different tooling from
# the local pass would produce findings developers cannot reproduce, which is how lint gates come to
# be ignored.
#
# Output, all under --out:
#   raw/<tool>.json      each detector's native output (kept for debugging and for CI artifacts)
#   raw/<tool>.skipped   why a tool did not run
#   SCAN.raw.json        normalized AgentContract, before diff-scoping
#   SCAN.json            the same, with findings not on changed lines removed  <-- what Claude reads
#   SCAN-SUMMARY.md      counts by tool and severity + the skipped-tool list
#   SCAN-CONTRACT-DEFECTS.md   only when a finding had to be repaired or dropped (tooling-owner note)
#
# EXIT STATUS
#   0  the scan completed, REGARDLESS of what it found. Findings are reported, not enforced; a scan
#      that failed the pipeline because `tflint` is missing from the image would be actively harmful.
#   2  the scan could not run or could not write its output: bad flag, bad ref, no git/python3,
#      unsafe --out, normalize.py or the summary failed. The message on stderr says which.
#
# Portable bash 3.2+ / zsh. No dependencies beyond git, python3, and whatever detectors are present.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DETECTOR_DIR="$SELF_DIR/detectors"
NORMALIZE="$SELF_DIR/normalize.py"
# The hunk-intersection filter already exists and is already tested; a second implementation would
# be a second thing to keep correct.
FILTER="$SELF_DIR/filter-carried-findings.py"

# MAX_FINDINGS is a reading budget, not a measured threshold: SCAN.json is read whole by the semantic
# agent, and each finding can carry about 1,100 characters (title 300, evidence 200, recommendation
# 600). Truncation is lowest-severity-first and is recorded in scan_meta, so raising the cap costs
# the reader tokens and lowering it drops only the least severe findings, visibly.
BASE="" SOURCE="HEAD" OUT=".code-review" ONLY="" MAX_FINDINGS=150 FAIL_UNDER="" QUIET=false

die() { printf 'review-scan: %s\n' "$*" >&2; exit 2; }
say() { $QUIET || printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: review-scan.sh [options]
  --base <ref>        merge base to diff against. Default: origin/HEAD, then origin/main, then
                      origin/master. An explicit ref must resolve; it is never substituted.
  --source <ref>      default HEAD
  --out <dir>         default .code-review
  --detectors a,b     only these detectors (default: chosen from the changed-file signals)
  --max-findings N    default 150; truncates lowest-severity-first and records the truncation
  --fail-under N      coverage gate; default: read from pyproject.toml / setup.cfg / .coveragerc
  --quiet             suppress this script's progress output on stderr
EOF
  exit 2
}

# Sourced BEFORE argument parsing, because the parser uses need_value from it. The --out guard lives
# here too, SOURCED rather than restated: it was once duplicated verbatim across this script and its
# sibling, in a change whose thesis is that a restated invariant drifts. A missing lib is a hard
# failure, never a silently-skipped guard.
. "$SELF_DIR/_lib.sh" || die "cannot source $SELF_DIR/_lib.sh — the --out safety guard is unavailable"

while [ $# -gt 0 ]; do
  case "$1" in
    --base) need_value "$1" $# "${2-}"; BASE="$2"; shift 2 ;;
    --source) need_value "$1" $# "${2-}"; SOURCE="$2"; shift 2 ;;
    --out) need_value "$1" $# "${2-}"; OUT="$2"; shift 2 ;;
    --detectors) need_value "$1" $# "${2-}"; ONLY="$2"; shift 2 ;;
    --max-findings) need_value "$1" $# "${2-}"; MAX_FINDINGS="$2"; shift 2 ;;
    --fail-under) need_value "$1" $# "${2-}"; FAIL_UNDER="$2"; shift 2 ;;
    --quiet) QUIET=true; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

# Validate every value BEFORE any detector runs. A bad --max-findings used to surface only when
# normalize.py's argparse rejected it, after the whole (possibly minutes-long) detector pass.
case "$MAX_FINDINGS" in
  ''|*[!0-9]*|0) die "--max-findings must be a positive integer, got '$MAX_FINDINGS'" ;;
esac
if [ -n "$FAIL_UNDER" ]; then
  case "$FAIL_UNDER" in
    *[!0-9.]*|.|*.*.*) die "--fail-under must be a number, got '$FAIL_UNDER'" ;;
  esac
fi
# Detector names become a path (`detectors/<name>.sh`), so only bare lowercase names are accepted:
# `--detectors ../x` would otherwise run any script on disk.
if [ -n "$ONLY" ]; then
  for _d in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case "$_d" in
      *[!a-z]*) die "--detectors: '$_d' is not a detector name (lowercase letters only; see detectors/)" ;;
    esac
  done
  unset _d
  # `--detectors ,` or `--detectors " "` passes the loop above with no names at all, and then ran no
  # detector and reported APPROVE over a scan that looked at nothing.
  [ -n "$(printf '%s' "$ONLY" | tr -d ', ')" ] || die "--detectors: no detector names given (got '$ONLY')"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
BASE="$(resolve_base "$BASE")" || die "cannot choose a base ref (see above)"
git rev-parse --verify --quiet "$SOURCE^{commit}" >/dev/null || die "source ref '$SOURCE' does not resolve"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || die "could not cd to repo root $REPO_ROOT"

require_safe_out "$OUT" || die "--out is unsafe (see above); refusing to write a '*' fence"
RAW="$OUT/raw"
mkdir -p "$RAW" || die "could not create $RAW"
# Fence the artifact ROOT, not raw/. A `.gitignore` containing `*` applies recursively, so one file
# at "$OUT/.gitignore" covers raw/, archive/ and every per-SHA subdirectory, including ones added
# later; a fence inside raw/ would leave SCAN.json and the archive exposed. Keeping the artifacts out
# of history cannot be left to the consuming repo remembering an entry — one real repo remembered
# `.orchestration/`, forgot `.code-review/`, and committed 33 artifact files.
# The `[ -e ]` guard is load-bearing: this runs on every scan, and a user-edited file survives.
# Escape hatch: delete "$OUT/.gitignore".
[ -e "$OUT/.gitignore" ] || printf '*\n' > "$OUT/.gitignore"
# A stale raw/ from a previous run would be silently re-normalized, so a tool that has since been
# uninstalled would still appear to have run. Clear only the files this script owns.
#
# INGESTED is the exception, and it is load-bearing. `detectors/python.sh` does not run the suite —
# it tells CI to "drop raw/pytest.json in from CI to ingest", because pytest and coverage need the
# project env and its services. A blanket `rm -f "$RAW"/*.json` deleted precisely those two files
# before the detectors ever looked for them, so the documented ingest contract could never fire and
# `pytest`/`coverage` recorded a skip in every run.
# These files are inputs to this script, not outputs of it.
INGESTED="pytest.json coverage.json"
for _f in "$RAW"/*.json "$RAW"/*.skipped; do
  [ -e "$_f" ] || continue          # unmatched glob stays literal in both bash and zsh
  _keep=false
  for _k in $INGESTED; do
    [ "${_f##*/}" = "$_k" ] && _keep=true
  done
  $_keep || rm -f "$_f"
done
unset _f _k _keep
# The contract banner is written only when there is something to say, so a banner left by an EARLIER
# run would be read as describing this one. Remove it up front; the annotate step rewrites it if needed.
rm -f "$OUT/SCAN-CONTRACT-DEFECTS.md"

# ---------------------------------------------------------------------------- changed files
CHANGED="$RAW/.changed"
DELETED="$RAW/.deleted"
# The scratch lists go on EVERY exit. `die` exits 2 part-way through, and an rm at the end of the
# script never ran on those paths, so the lists were left in raw/.
trap 'rm -f "$CHANGED" "$CHANGED.all" "$CHANGED.unlisted" "$DELETED" "$DELETED.all" "$DELETED.unlisted" "$RAW/.filter.err" 2>/dev/null' EXIT
# Three-dot: changes on the source side since the merge base, NOT everything that happened on main
# in the meantime. Two dots here would attribute other people's commits to this change.
list_changed "$BASE...$SOURCE" "$CHANGED.all" "$CHANGED.unlisted" \
  || die "git diff $BASE...$SOURCE failed"
# Deleted files, listed apart: nothing can lint them, but a deleted definition breaks every consumer
# still importing it, and impact.sh is what finds those. Without this list a change that deleted a
# whole file scanned "0 changed files" and ran no detector at all.
list_changed "$BASE...$SOURCE" "$DELETED.all" "$DELETED.unlisted" D \
  || die "git diff $BASE...$SOURCE failed"
cat "$DELETED.unlisted" >> "$CHANGED.unlisted"
if [ -s "$CHANGED.unlisted" ]; then
  # Recorded as a coverage gap, never dropped silently: the detector contract is one path per line,
  # so a path containing a newline cannot be handed to any detector.
  printf '%s changed file(s) have a newline in the name and were not scanned: %s\n' \
    "$(grep -c . "$CHANGED.unlisted")" "$(head -c 200 "$CHANGED.unlisted" | tr '\n' ' ')" \
    > "$RAW/changed-files.skipped"
fi

# Generated files: one list, in _lib.sh, shared with prepare-context.sh so the scanner and the
# semantic agent agree on which files are even in the change. Linting a lockfile or a minified bundle
# produces findings nobody will ever act on.
drop_generated "$CHANGED.all" "$CHANGED"
drop_generated "$DELETED.all" "$DELETED"

# `grep -c` prints 0 AND exits 1 when nothing matches, so a `|| printf '0'` fallback appends a
# second zero and the variable becomes "0\n0" — which then breaks the arithmetic below and swallowed
# the whole count line. Take grep's own output and default only if the variable is empty.
N_ALL=$(grep -c '[^[:space:]]' "$CHANGED.all" 2>/dev/null)
N_KEPT=$(grep -c '[^[:space:]]' "$CHANGED" 2>/dev/null)
N_ALL=${N_ALL:-0}
N_KEPT=${N_KEPT:-0}
N_DELETED=$(grep -c '[^[:space:]]' "$DELETED" 2>/dev/null)
N_DELETED=${N_DELETED:-0}
say "review-scan: $N_KEPT changed file(s) to scan ($((N_ALL - N_KEPT)) generated/excluded), $N_DELETED deleted"

# ---------------------------------------------------------------------------- worktree check
# Detectors lint the files ON DISK, while the hunk filter diffs BASE...SOURCE. When those are not the
# same content the findings' line numbers belong to a different file version, and the filter keeps or
# drops them against the wrong lines. Two ways that happens: SOURCE is not what is checked out, or a
# changed file has uncommitted edits. Both are stated in SCAN.json and on stderr rather than refused,
# because reviewing a ref you have not checked out is a legitimate (if lossy) thing to do.
WORKTREE_NOTE=""
HEAD_SHA="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || HEAD_SHA=""
SOURCE_SHA="$(git rev-parse --verify --quiet "$SOURCE^{commit}")"
if [ "$HEAD_SHA" != "$SOURCE_SHA" ]; then
  WORKTREE_NOTE="WORKTREE MISMATCH: the working tree is at $(printf '%.12s' "${HEAD_SHA:-?}") but the scan diffed $SOURCE ($(printf '%.12s' "$SOURCE_SHA")). Detectors lint the files on disk, so findings and their line numbers describe the working tree, not the reviewed ref. Check out $SOURCE and re-run for trustworthy results."
else
  _dirty=""
  git -c core.quotePath=false diff --name-only HEAD > "$RAW/.dirty" 2>/dev/null || : > "$RAW/.dirty"
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    grep -qxF -- "$_f" "$CHANGED" && _dirty="$_dirty $_f"
  done < "$RAW/.dirty"
  rm -f "$RAW/.dirty"
  if [ -n "$_dirty" ]; then
    WORKTREE_NOTE="WORKTREE MISMATCH: changed file(s) have uncommitted edits:$_dirty. Detectors lint the files on disk, so findings there may cite lines that differ from $SOURCE. Commit or stash and re-run for trustworthy results."
  fi
  unset _dirty _f
fi
[ -n "$WORKTREE_NOTE" ] && say "  warn: $WORKTREE_NOTE"

# ---------------------------------------------------------------------------- stack signals
# Deliberately derived from the changed-file list ALONE — never a tree walk. Same case arms as
# the review skill's stack-detection step so the two paths cannot drift on what counts as "IaC" or "frontend".
SIG_CODE=false SIG_IAC=false SIG_SHELL=false SIG_WEB=false SIG_MANIFEST=false SIG_POLICY=false SIG_ANY=false
while IFS= read -r f; do
  [ -n "$f" ] || continue
  SIG_ANY=true
  case "$f" in
    *.py|*.ts|*.tsx|*.js|*.jsx|*.go|*.rb|*.java|*.rs|*.php|*.cs) SIG_CODE=true ;;
  esac
  case "$f" in *.tf|*.tfvars|*.hcl) SIG_IAC=true ;; esac
  case "$f" in *.sh|*.bash|*.zsh) SIG_SHELL=true ;; esac
  case "$f" in *.ts|*.tsx|*.js|*.jsx|*.mjs) SIG_WEB=true ;; esac
  # The one signal that is a PATH SHAPE rather than an extension, because what it selects has no
  # extension to select on: `package.json` is a dependency manifest and `tsconfig.json` is not, and
  # `Dockerfile` has no suffix at all. The arms are the same list `detectors/deps.sh` filters on, and
  # the two must stay identical — a signal that is wider dispatches a detector that then skips, and
  # one that is narrower silently declines to scan a manifest the detector would have read.
  case "$f" in
    package.json|*/package.json) SIG_MANIFEST=true ;;
    requirements.txt|*/requirements.txt|requirements-*.txt|*/requirements-*.txt) SIG_MANIFEST=true ;;
    pyproject.toml|*/pyproject.toml) SIG_MANIFEST=true ;;
    Dockerfile|*/Dockerfile|Dockerfile.*|*/Dockerfile.*|*.Dockerfile) SIG_MANIFEST=true ;;
    .github/workflows/*.yml|.github/workflows/*.yaml) SIG_MANIFEST=true ;;
    */.github/workflows/*.yml|*/.github/workflows/*.yaml) SIG_MANIFEST=true ;;
    .pre-commit-config.yaml|*/.pre-commit-config.yaml) SIG_MANIFEST=true ;;
    .pre-commit-config.yml|*/.pre-commit-config.yml) SIG_MANIFEST=true ;;
  esac
  # iac-policy's file selection: Terraform, CI pipelines, Makefiles and SQL. Same arms as the
  # selection in detectors/iac-policy.sh; the two must stay identical, like SIG_MANIFEST and deps.sh.
  case "$f" in
    *.tf|*.hcl|*.tfbackend|*.sql) SIG_POLICY=true ;;
    .github/workflows/*.yml|.github/workflows/*.yaml|*/.github/workflows/*.yml|*/.github/workflows/*.yaml) SIG_POLICY=true ;;
    .gitlab-ci.yml|*/.gitlab-ci.yml|*.gitlab-ci.yml|.circleci/*.yml|azure-pipelines.yml|bitbucket-pipelines.yml|.buildkite/*.yml) SIG_POLICY=true ;;
    Jenkinsfile|*/Jenkinsfile|Jenkinsfile.*|*/Jenkinsfile.*|Makefile|*/Makefile|*.mk) SIG_POLICY=true ;;
  esac
done < "$CHANGED"

if $SIG_WEB; then
  # Neither semgrep nor eslint is installed on the reference machine, and `tsc` needs the project's
  # tsconfig and node_modules to say anything useful. So TS/JS gets secrets + impact only. Recording
  # it as a skip is the whole mitigation: the summary must not let a TS-heavy change read as scanned.
  printf '%s\n' \
    "no TS/JS linter available (semgrep and eslint are not installed; tsc needs the project's node_modules) — TS/JS files were covered by the secrets and impact detectors only" \
    > "$RAW/typescript.skipped"
fi

# secrets always runs when anything changed: a credential is not a property of a stack, and it is
# the one finding class where a miss is an incident rather than a review comment.
DETECTORS=""
if [ -n "$ONLY" ]; then
  DETECTORS="$(printf '%s' "$ONLY" | tr ',' ' ')"
else
  $SIG_CODE && DETECTORS="$DETECTORS python"
  $SIG_IAC && DETECTORS="$DETECTORS terraform"
  $SIG_SHELL && DETECTORS="$DETECTORS shell"
  $SIG_MANIFEST && DETECTORS="$DETECTORS deps"
  $SIG_POLICY && DETECTORS="$DETECTORS iac-policy"
  # `comments` follows the source signals rather than a signal of its own: its file list is source
  # files with an unambiguous line-comment token, which is exactly SIG_CODE plus shell and HCL.
  { $SIG_CODE || $SIG_SHELL || $SIG_IAC; } && DETECTORS="$DETECTORS comments"
  if $SIG_ANY; then
    DETECTORS="$DETECTORS secrets impact"
  elif [ "$N_DELETED" -gt 0 ]; then
    DETECTORS="$DETECTORS impact"      # a deletion-only change: consumers of what was removed
  fi
fi

if [ -z "${DETECTORS# }" ]; then
  say "review-scan: nothing to scan (no non-generated changed files)"
fi

# ---------------------------------------------------------------------------- run detectors
# impact.sh needs the refs, which are not in the detector argv contract.
# SCAN_DELETED names the deleted-files list, for impact.sh, which checks what a deletion removed.
SCAN_BASE="$BASE" SCAN_SOURCE="$SOURCE" SCAN_DELETED="$DELETED"
export SCAN_BASE SCAN_SOURCE SCAN_DELETED

for d in $DETECTORS; do
  script="$DETECTOR_DIR/$d.sh"
  if [ ! -f "$script" ]; then
    printf 'no such detector: %s\n' "$d" > "$RAW/$d.skipped"
    say "  skip $d — no such detector"
    continue
  fi
  say "  run  $d"
  # Detectors always exit 0 by contract; `|| true` is belt-and-braces so a detector that violates
  # the contract still cannot abort the scan under `set -e`-ish conditions.
  bash "$script" "$CHANGED" "$OUT" || true
done

# ---------------------------------------------------------------------------- coverage gate
if [ -z "$FAIL_UNDER" ]; then
  # coverage.py's own config key, in the three places it is normally written. Only used when a
  # coverage.json is present, so a repo without coverage pays nothing for this.
  for cfg in pyproject.toml setup.cfg .coveragerc; do
    [ -f "$cfg" ] || continue
    v="$(grep -E '^[[:space:]]*fail_under[[:space:]]*=' "$cfg" 2>/dev/null | head -1 |
         sed -E 's/.*=[[:space:]]*([0-9.]+).*/\1/')"
    if [ -n "$v" ]; then FAIL_UNDER="$v"; break; fi
  done
fi

# ---------------------------------------------------------------------------- normalize
set -- --raw "$RAW" --out "$OUT/SCAN.raw.json" --repo-root "$REPO_ROOT" \
  --source-branch "$SOURCE" --target-branch "$BASE" --max-findings "$MAX_FINDINGS"
[ -n "$FAIL_UNDER" ] && set -- "$@" --fail-under "$FAIL_UNDER"
python3 "$NORMALIZE" "$@" || die "normalize.py failed"

# ---------------------------------------------------------------------------- diff-scope
# Everything the scanner emits is marked in_diff:true, so the filter hunk-checks every finding and
# drops the ones whose cited lines are not on changed lines. This is what stops a repo's existing
# lint debt from arriving as 400 findings about code the change never touched. (Findings deliberately
# marked in_diff:false — the coverage gate — are kept by the filter untouched.)
SCOPED=false
if [ -f "$FILTER" ]; then
  if python3 "$FILTER" --in "$OUT/SCAN.raw.json" --out "$OUT/SCAN.json" \
       --target "$BASE" --source "$SOURCE" >/dev/null 2>"$RAW/.filter.err"; then
    SCOPED=true
  else
    say "  warn: diff filter failed — $(head -c 200 "$RAW/.filter.err" | tr '\n' ' ')"
  fi
else
  say "  warn: $FILTER not found — findings are NOT diff-scoped"
fi

if ! $SCOPED; then
  # Fall back to the unscoped contract rather than emitting nothing, but record it loudly: an
  # unscoped SCAN.json carries pre-existing debt, and the reader has to know that before triaging.
  cp "$OUT/SCAN.raw.json" "$OUT/SCAN.json" || die "could not write $OUT/SCAN.json"
fi

python3 - "$OUT/SCAN.json" "$SCOPED" "$SELF_DIR" "$WORKTREE_NOTE" <<'PY'
import json, os, sys
path, scoped = sys.argv[1], sys.argv[2] == "true"
worktree_note = sys.argv[4] if len(sys.argv) > 4 else ""

# This is `python3 -`, so sys.path[0] is the CWD — and the CWD here is the REVIEWED repo, not the
# pipeline. argv[3] is this script's own $SELF_DIR, which makes the ONE contract definition
# importable instead of restated a fourth time. Do not "simplify" the argv away: a bare
# `from contract import ...` searches the reviewed repo's root and raises mid-scan.
sys.path.insert(0, sys.argv[3])
from contract import (canon_severity, contract_defects, finding_blocks,
                      finding_escalates, floor_diagnostics, normalize_finding)

# THE PREDICATE IS IMPORTED, NOT RESTATED. This block used to be a fourth copy of it, kept
# "byte-identical in intent" by hand. It is now `from contract import ...` above, which is the whole
# point: a copy that can import has no reason to be a copy. No prose copy of the predicate is
# maintained either: the `dev-standards:agent-contracts` skill gives a one-line summary and points to
# contract.py, and `agents/review-validator.md` only records judgements.
_sev = canon_severity
_blocks = finding_blocks
_escalates = finding_escalates

_FLOOR_RANK, _FLOOR_NOTE = floor_diagnostics()

try:
    with open(path) as fh:
        doc = json.load(fh)
except (OSError, ValueError) as exc:
    sys.exit(f"could not annotate {path}: {exc}")
meta = doc.setdefault("scan_meta", {})
meta["diff_scoped"] = scoped
# A configured floor that is accepted but does not mean what the reader thinks must SAY so. `NIT`
# (and its deprecated spelling `INFO`) resolve to the bottom tier, which is structurally
# non-blocking, so they behave exactly like the default MINOR — someone who set `NIT` expecting
# "block on everything" silently got "block on MINOR and above". An unrecognised value falls back to
# the strict default, which is also worth a line: a typo in a gate's configuration must not widen it
# quietly. Both cases are reported, neither changes behaviour.
if _FLOOR_NOTE:
    meta.setdefault("notes", []).append(_FLOOR_NOTE)
    sys.stderr.write(f"review-scan: {_FLOOR_NOTE}\n")
if worktree_note:
    meta["worktree_matches_source"] = False
    meta.setdefault("notes", []).append(worktree_note)
if not scoped:
    meta.setdefault("notes", []).append(
        "DIFF SCOPING DID NOT RUN — findings may be pre-existing debt outside this change. "
        "Verify each location is on a changed line before reporting it.")
# ---- contract pass: REPAIR FIRST, then partition. Runs BEFORE the recount and before the
# verdict, because a finding the repair rescues must be counted AND must be allowed to block.
# Order is the whole point: gating before repairing would reject 8 of the 9 real artifacts this
# gate was built from, all of which carried the same information under different key names.
#
# Findings reaching here from normalize.py always carry all ten keys (mk() builds them), so on the
# scanner path this is a no-op. It exists for the CI-published-report ingest path and for anything
# else that hands a foreign artifact to this script.
_repairs, _rejected, _kept = [], [], []
for _i, _f in enumerate(doc.get("findings") or []):
    _fixed, _r = normalize_finding(_f, index=_i)
    if _r:
        _repairs.append({"index": _i, "id": (_fixed.get("id") if isinstance(_fixed, dict) else None),
                         "repairs": _r})
    _d = contract_defects(_fixed)
    if _d:
        # DROPPED from the author-facing list but NOT deleted: the raw object rides along so the
        # tooling owner can see what the producer actually emitted. Nothing here reaches the
        # verdict — an author cannot fix the review tooling, so this must not gate their merge.
        _rejected.append({"index": _i, "defects": _d, "raw": _f})
    else:
        _kept.append(_fixed)
doc["findings"] = _kept
# The SECOND escalation target, and deliberately NOT the verdict. `verdict` is the reviewer-facing
# channel (APPROVE / REQUEST_CHANGES / INCOMPLETE) and stays a three-value enum; `contract_health`
# is the tooling-owner channel. Two targets, two people. Adding a fourth verdict value would point
# the wrong person at a problem they cannot fix.
if _repairs or _rejected:
    doc["contract_health"] = {"repaired": len(_repairs), "rejected": len(_rejected),
                              "repairs": _repairs, "defects": _rejected}
    meta.setdefault("notes", []).append(
        f"CONTRACT: {len(_repairs)} finding(s) repaired onto the canonical keys, "
        f"{len(_rejected)} dropped as contentless. This is a defect in the review pipeline's "
        "own output, not in the reviewed change — see "
        + os.path.join(os.path.dirname(path), "SCAN-CONTRACT-DEFECTS.md") + ".")

# Recount after filtering: the pre-filter metrics would overstate every severity bucket, and the
# verdict is derived from them.
sev = {"BLOCKER": 0, "MAJOR": 0, "MINOR": 0, "NIT": 0}
unknown_sev = 0
by_tool = {}
for f in doc.get("findings") or []:
    # Was `if f.get("severity") in sev`, which silently dropped an unrecognised severity
    # from EVERY bucket while leaving it in `findings` — so the counts and the list a human
    # reads disagreed, and nothing said so. Canonicalise, then count the residue explicitly.
    #
    # `f.get("severity")`, NOT `f`. canon_severity takes a VALUE; handed a whole finding dict it
    # does `str(dict).upper()`, which is never in SEVERITY_RANK, so it returns "" for EVERY
    # finding — every bucket zero, every finding counted as unrankable, and a scan_meta note
    # asserting the severities cannot be ranked when they are all perfectly valid. That is the
    # self-contradicting report this very rewrite exists to prevent, and it shipped inside the fix.
    # It survived review because the shape test ran over a findings-FREE fixture, so the loop body
    # never executed; the test below now uses a populated one.
    s = _sev(f.get("severity"))
    if s:
        sev[s] += 1
    else:
        unknown_sev += 1
    t = f.get("tool") or "unknown"
    by_tool[t] = by_tool.get(t, 0) + 1
m = doc.setdefault("metrics", {})
m["total"] = len(doc.get("findings") or [])
m["blocker"], m["major"] = sev["BLOCKER"], sev["MAJOR"]
m["minor"], m["nit"] = sev["MINOR"], sev["NIT"]
meta["by_tool"] = by_tool
if unknown_sev:
    meta.setdefault("notes", []).append(
        f"{unknown_sev} finding(s) carry a severity this pipeline cannot rank; they are in "
        "`findings` but in no severity bucket, and they never block. Fix the emitting detector.")
# The blocking floor decides, defaulting to MINOR since 3.0.0. Derived from the
# findings, not from `sev`, because the counts carry neither in_diff nor confidence — and
# INCOMPLETE (a finding that could not be resolved to HIGH confidence) is a state the counts
# cannot express at all.
_findings = doc.get("findings") or []
if any(_blocks(f) for f in _findings):
    doc["verdict"] = "REQUEST_CHANGES"
elif any(_escalates(f) for f in _findings):
    doc["verdict"] = "INCOMPLETE"
else:
    doc["verdict"] = "APPROVE"
with open(path, "w") as fh:
    json.dump(doc, fh, indent=2)

# The scanner's CONTRACT BANNER. Named SCAN-CONTRACT-DEFECTS.md, not CONTRACT-DEFECTS.md: that name
# belongs to `contract.py finalize`, which writes the review-wide banner after the validator, and a
# scanner banner under the same name would be read as the review's. Written only when there is
# something to say; a banner from an earlier run is removed at the top of this script.
if _repairs or _rejected:
    _banner = os.path.join(os.path.dirname(path), "SCAN-CONTRACT-DEFECTS.md")
    with open(_banner, "w") as fh:
        fh.write("# Contract defects — for the TOOLING OWNER, not the change author\n\n")
        fh.write("These are defects in the review pipeline's own output. They do not affect the "
                 "verdict, and the author of the reviewed change cannot fix them.\n\n")
        fh.write(f"- repaired onto the canonical keys: {len(_repairs)}\n")
        fh.write(f"- dropped as contentless: {len(_rejected)}\n\n")
        for _e in _repairs:
            fh.write(f"- REPAIRED `{_e.get('id')}` (index {_e['index']}): "
                     + "; ".join(_e["repairs"]) + "\n")
        for _e in _rejected:
            fh.write(f"- DROPPED index {_e['index']}: " + ", ".join(_e["defects"])
                     + f"\n  raw: `{json.dumps(_e['raw'])[:400]}`\n")
PY
[ $? -eq 0 ] || die "could not annotate $OUT/SCAN.json"

# ---------------------------------------------------------------------------- summary
python3 - "$OUT/SCAN.json" "$OUT/SCAN-SUMMARY.md" "$N_KEPT" "$N_ALL" <<'PY'
import json, sys
scan_path, out_path, n_kept, n_all = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(scan_path) as fh:
    doc = json.load(fh)
m = doc.get("metrics") or {}
meta = doc.get("scan_meta") or {}
L = []
A = L.append
A("# Scan summary\n")
A(f"- Base: `{doc.get('target_branch')}` → source: `{doc.get('source_branch')}`")
A(f"- Files: {n_kept} scanned of {n_all} changed (rest generated/excluded)")
A(f"- Diff-scoped: {'yes' if meta.get('diff_scoped') else '**NO — see notes**'}")
A(f"- Verdict from the deterministic pass alone: **{doc.get('verdict')}**\n")
A("| Severity | Count |")
A("| --- | --- |")
for s in ("blocker", "major", "minor", "nit"):
    A(f"| {s.upper()} | {m.get(s, 0)} |")
A(f"| **total** | **{m.get('total', 0)}** |\n")

by_tool = meta.get("by_tool") or {}
if by_tool:
    A("| Tool | Findings |")
    A("| --- | --- |")
    for t in sorted(by_tool, key=lambda k: (-by_tool[k], k)):
        A(f"| {t} | {by_tool[t]} |")
    A("")

ran = meta.get("tools_run") or []
A(f"Detectors that produced output: {', '.join(ran) if ran else '(none)'}\n")

# The skipped list is the most important part of this file. A scan with six of nine tools present
# looks identical to a clean scan unless the gaps are stated, and a reviewer who does not know
# `bandit` never ran will read a silent SCAN.json as "no security findings".
skipped = meta.get("tools_skipped") or []
if skipped:
    A("## Coverage gaps\n")
    for s in skipped:
        A(f"- **SKIPPED: {s.get('tool')}** — {s.get('reason') or 'no reason recorded'}")
    A("")
    A(f"This scan ran {len(ran)} of {len(ran) + len(skipped)} detectors. Treat the skipped areas as "
      "unscanned, not as clean.\n")
else:
    A("No detectors were skipped.\n")

if meta.get("truncated_findings"):
    A(f"**{meta['truncated_findings']} finding(s) were truncated** (lowest severity first) to stay "
      "inside the finding cap.\n")
for n in meta.get("notes") or []:
    A(f"> {n}\n")
try:
    with open(out_path, "w") as fh:
        fh.write("\n".join(L))
except OSError as exc:
    sys.exit(f"could not write {out_path}: {exc}")
print(f"{m.get('total', 0)} finding(s): "
      f"{m.get('blocker', 0)} blocker / {m.get('major', 0)} major / "
      f"{m.get('minor', 0)} minor / {m.get('nit', 0)} nit")
PY
# Was unchecked: a summary that failed to write still ended in "wrote ... SCAN-SUMMARY.md" and exit 0.
[ $? -eq 0 ] || die "could not write $OUT/SCAN-SUMMARY.md"

say "review-scan: wrote $OUT/SCAN.json and $OUT/SCAN-SUMMARY.md"
exit 0
