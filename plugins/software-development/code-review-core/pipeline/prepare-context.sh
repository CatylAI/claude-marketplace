#!/usr/bin/env bash
# prepare-context.sh — build the entire bounded input set for a detection-first code review, deterministically.
#
#   prepare-context.sh [--base <ref>] [--source <ref>] [--out .code-review] [--effort low|medium|high]
#
# Runs the zero-token detection pass (review-scan.sh) and then assembles everything the semantic
# agent is allowed to read, with a hard cap on every input:
#
#   DIFF.md       git diff -U3 of the changed source files, per-file capped, generated files excluded
#   CONTEXT.json  refs, changed files, stack signals, scan metrics, and the architect-gate decision
#
# WHY THIS IS A SCRIPT AND NOT PROMPT TEXT. The legacy pipeline gated its expensive agents with
# instructions inside an agent prompt ("skip the whole-tree sweep when the diff is contained"), so the
# gate was evaluated by the model being gated — it could and did decide to sweep anyway. Every gate
# here is a shell condition whose decision is recorded in CONTEXT.json with a reason. A caller can
# diff two runs and see exactly why the architect was or was not spawned.
#
# EXIT STATUS
#   0  the context was built, whatever the scan found (a failed scan is recorded, not fatal).
#   2  it could not be built at all: bad flag, bad ref, not a git repo, unsafe --out, or the Python
#      assembly step failed. The message on stderr says which.
#
# Portable bash 3.2+ / zsh. Depends on git and python3 only.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCANNER="$SELF_DIR/review-scan.sh"

# The two DIFF.md budgets. They are reading budgets, not measured thresholds: DIFF.md is the
# largest thing the semantic agent reads, so these set how much of its context the diff may take.
# With the 60-line per-file floor below, 1500 lines gives about 25 source files a full share; files past
# that get the MIN_SLICE minimum. Every omission and truncation is recorded in CONTEXT.json, so the
# reviewer sees what was cut. Tune with --max-diff-lines / --max-diff-files.
BASE="" SOURCE="HEAD" OUT=".code-review" EFFORT="medium"
MAX_DIFF_LINES=1500 MAX_DIFF_FILES=40 SKIP_SCAN=false QUIET=false

die() { printf 'prepare-context: %s\n' "$*" >&2; exit 2; }
say() { $QUIET || printf '%s\n' "$*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: prepare-context.sh [options]
  --base <ref>          merge base. Default: origin/HEAD, then origin/main, then origin/master.
                        An explicit ref must resolve; it is never substituted.
  --source <ref>        default HEAD
  --out <dir>           default .code-review
  --effort low|medium|high   default medium; low never spawns the architect, high always does
  --max-diff-lines N    default 1500; total DIFF.md budget
  --max-diff-files N    default 40
  --skip-scan           do not run review-scan.sh (SCAN.json already exists, e.g. a CI artifact)
  --quiet               suppress progress output on stderr
EOF
  exit 2
}

# Sourced BEFORE argument parsing, because the parser uses need_value from it. The --out guard lives
# here too, SOURCED rather than restated, so the two entry points cannot drift on it. A missing lib is
# a hard failure, never a silently-skipped guard.
. "$SELF_DIR/_lib.sh" || die "cannot source $SELF_DIR/_lib.sh — the --out safety guard is unavailable"

while [ $# -gt 0 ]; do
  case "$1" in
    --base) need_value "$1" $# "${2-}"; BASE="$2"; shift 2 ;;
    --source) need_value "$1" $# "${2-}"; SOURCE="$2"; shift 2 ;;
    --out) need_value "$1" $# "${2-}"; OUT="$2"; shift 2 ;;
    --effort) need_value "$1" $# "${2-}"; EFFORT="$2"; shift 2 ;;
    --max-diff-lines) need_value "$1" $# "${2-}"; MAX_DIFF_LINES="$2"; shift 2 ;;
    --max-diff-files) need_value "$1" $# "${2-}"; MAX_DIFF_FILES="$2"; shift 2 ;;
    --skip-scan) SKIP_SCAN=true; shift ;;
    --quiet) QUIET=true; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

case "$EFFORT" in low|medium|high) ;; *) die "invalid --effort '$EFFORT' (low|medium|high)" ;; esac
case "$MAX_DIFF_LINES" in ''|*[!0-9]*|0) die "--max-diff-lines must be a positive integer, got '$MAX_DIFF_LINES'" ;; esac
case "$MAX_DIFF_FILES" in ''|*[!0-9]*|0) die "--max-diff-files must be a positive integer, got '$MAX_DIFF_FILES'" ;; esac
command -v git >/dev/null 2>&1 || die "git not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
BASE="$(resolve_base "$BASE")" || die "cannot choose a base ref (see above)"
git rev-parse --verify --quiet "$SOURCE^{commit}" >/dev/null || die "source ref '$SOURCE' does not resolve"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || die "could not cd to repo root $REPO_ROOT"

require_safe_out "$OUT" || die "--out is unsafe (see above); refusing to write a '*' fence"
mkdir -p "$OUT" || die "could not create $OUT"
# Fence the artifact directory at creation. Whether review artifacts stay out of history must not
# depend on the CONSUMING repo having remembered a `.gitignore` entry: one real repo remembered
# `.orchestration/` and forgot `.code-review/`, and has 33 tracked `.code-review/` files to show for it.
# `*` applies recursively, so this one file covers raw/, archive/ and every per-SHA subdirectory,
# including ones added later — which is why the fence goes on $OUT and not on a child.
# The `[ -e ]` guard is load-bearing: these mkdirs run several times per review, and a repo that has
# deliberately customised the file keeps it. Escape hatch: delete "$OUT/.gitignore" and the artifacts
# become committable again.
[ -e "$OUT/.gitignore" ] || printf '*\n' > "$OUT/.gitignore"

# Remove the previous review's agent and validator artifacts before anything else runs. They are all
# written later in THIS review, and a leftover one is read as current: a stale VALIDATOR-DECISIONS.json
# was applied to the new findings, and a stale TESTING.json satisfied a gate whose agent never ran.
# SCAN.json is not in the list; review-scan.sh rewrites it, and --skip-scan relies on keeping it.
for _f in SEMANTIC.json TESTING.json ARCHITECTURE.json ARCHITECTURE.md CLAUDE_CONFIG.json \
          VALIDATOR-DECISIONS.json VALIDATED.json VALIDATED.md CONTRACT-DEFECTS.md; do
  rm -f "$OUT/$_f"
done
unset _f

REVIEWED_SHA="$(git rev-parse "$SOURCE")"
# The semantic agent has no Bash and reads repository files off the WORKING TREE, so every prompt on
# both paths tells it "the working tree IS the head commit". That is true when --source defaults to
# HEAD and for a normal review of your own branch — but a caller reviewing a pushed branch sets
# REVIEWED_REF="origin/$SOURCE_BRANCH" when that ref exists, and nothing
# checks it out. Reviewing a peer's change, or your own branch after someone pushed to it, therefore
# diffs one commit while the agent reads another: DIFF.md is right, every Read is silently stale, and
# a finding cites a line number that does not exist in the reviewed code. Record the comparison here
# so the agents can branch on a fact instead of an assumption that is usually, but not always, true.
WORKTREE_SHA="$(git rev-parse HEAD 2>/dev/null)" || WORKTREE_SHA=""
# Branch names are informational — every git command below uses the refs. Derive them anyway so
# VALIDATED.json carries the same source_branch/target_branch the legacy path recorded.
if [ "$SOURCE" = "HEAD" ]; then
  SOURCE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$SOURCE_BRANCH" = "HEAD" ] && SOURCE_BRANCH="$REVIEWED_SHA"   # detached checkout
else
  SOURCE_BRANCH="$SOURCE"
fi
TARGET_BRANCH="$(printf '%s' "$BASE" | sed -E 's#^origin/##')"

# ---------------------------------------------------------------------------- detection pass
if $SKIP_SCAN; then
  say "prepare-context: --skip-scan (expecting an existing $OUT/SCAN.json)"
elif [ -x "$SCANNER" ]; then
  say "prepare-context: running the deterministic scan"
  # The scanner exits 0 whatever it finds and writes its own skip records; a non-zero here means it
  # could not run at all, which is a coverage gap, not a reason to abandon the review.
  # Accumulate the optional flag into "$@" — zsh does not word-split an unquoted expansion, so
  # ${QUIET:+--quiet} would arrive as one empty argument there and as nothing in bash.
  if $QUIET; then set -- --quiet; else set --; fi
  if ! bash "$SCANNER" --base "$BASE" --source "$SOURCE" --out "$OUT" "$@"; then
    say "prepare-context: warn — review-scan.sh exited non-zero; continuing without SCAN.json"
  fi
else
  say "prepare-context: warn — scanner not found at $SCANNER; continuing without SCAN.json"
fi

# ---------------------------------------------------------------------------- changed files
CHANGED="$OUT/.changed"
DELETED="$OUT/.deleted"
# The scratch lists go on EVERY exit, including a `die` part-way through; an rm at the end of the
# script left them behind whenever the context step failed.
trap 'rm -f "$CHANGED" "$CHANGED.all" "$CHANGED.unlisted" "$DELETED" "$DELETED.all" "$DELETED.unlisted" 2>/dev/null' EXIT
# NUL-safe and unquoted (see list_changed in _lib.sh): a non-ASCII name used to arrive C-quoted and
# match nothing on disk.
list_changed "$BASE...$SOURCE" "$CHANGED.all" "$CHANGED.unlisted" \
  || die "git diff $BASE...$SOURCE failed"
# Deleted files, listed apart so their hunks still reach DIFF.md. Without them a change that deleted
# a whole file showed the reviewer an empty diff.
list_changed "$BASE...$SOURCE" "$DELETED.all" "$DELETED.unlisted" D \
  || die "git diff $BASE...$SOURCE failed"
cat "$DELETED.unlisted" >> "$CHANGED.unlisted"
if [ -s "$CHANGED.unlisted" ]; then
  say "prepare-context: warn — $(grep -c . "$CHANGED.unlisted") changed file(s) have a newline in the name and are left out of DIFF.md and CONTEXT.json"
fi

# The generated-file list lives in _lib.sh and is shared with review-scan.sh, so the scanner and the
# semantic agent agree on which files are even in the change.
drop_generated "$CHANGED.all" "$CHANGED"
drop_generated "$DELETED.all" "$DELETED"

# grep -c prints its own 0 and ALSO exits 1 on no match, so a `|| printf 0` fallback yields "0\n0"
# and breaks the arithmetic. Default only when the variable came back empty.
N_ALL=$(grep -c '[^[:space:]]' "$CHANGED.all" 2>/dev/null); N_ALL=${N_ALL:-0}
N_KEPT=$(grep -c '[^[:space:]]' "$CHANGED" 2>/dev/null); N_KEPT=${N_KEPT:-0}
say "prepare-context: $N_KEPT changed file(s) ($((N_ALL - N_KEPT)) generated/excluded)"

# ---------------------------------------------------------------------------- repo-authored guidance
# `.claude-invariants.json` is the one pipeline input the author of the code under review also
# writes, which is why the agents treat it as ADDITIVE ONLY (it can add checks, never waive them). The cap here is
# the other half of that rule: an unbounded repo-authored file is an unbounded prompt-injection
# surface, and it is billed at cache-write rates against an agent whose whole context budget is
# 6-10k tokens.
#
# It CANNOT be a truncation. This script advertises only the PATH; the agent opens the file itself,
# so a truncated copy would never be the copy that gets read. Refusing to advertise is the only cap
# available at this layer, which is also why the reason is recorded: a bare null `invariants_path` is
# indistinguishable from "this repo has no invariants file", and a reviewer who cannot tell those
# apart cannot tell that a check they wrote was silently never applied.
#
# 8192 bytes is roughly 2,000 tokens: a deliberate ceiling on how much of an agent's budget
# repo-authored text may claim, and still room for a few dozen one-line invariants.
INVARIANTS_MAX_BYTES=8192
INVARIANTS=""
INVARIANTS_REASON="absent: no .claude-invariants.json in the repository root"
if [ -f .claude-invariants.json ]; then
  # `wc -c` pads its output with spaces on macOS, so strip whitespace; otherwise `-gt` is handed
  # "    9014" and errors with "integer expression expected" instead of comparing.
  INV_BYTES=$(wc -c < .claude-invariants.json 2>/dev/null | tr -d '[:space:]')
  INV_BYTES=${INV_BYTES:-0}
  if [ "$INV_BYTES" -gt "$INVARIANTS_MAX_BYTES" ]; then
    INVARIANTS_REASON="present but NOT advertised: ${INV_BYTES} bytes exceeds the ${INVARIANTS_MAX_BYTES}-byte cap on repo-authored guidance"
    say "prepare-context: warn — .claude-invariants.json is $INV_BYTES bytes (cap $INVARIANTS_MAX_BYTES); NOT advertising it to the agents"
  else
    INVARIANTS=".claude-invariants.json"
    INVARIANTS_REASON="advertised: ${INV_BYTES} bytes, within the ${INVARIANTS_MAX_BYTES}-byte cap"
  fi
fi

# ---------------------------------------------------------------------------- diff + context
python3 - \
  "$CHANGED" "$OUT" "$BASE" "$SOURCE" "$SOURCE_BRANCH" "$TARGET_BRANCH" "$REVIEWED_SHA" \
  "$EFFORT" "$MAX_DIFF_LINES" "$MAX_DIFF_FILES" "$N_ALL" "$N_KEPT" "$INVARIANTS" \
  "$INVARIANTS_REASON" "$WORKTREE_SHA" "$SELF_DIR" "$DELETED" <<'PY'
import json, os, re, subprocess, sys

(changed_path, out_dir, base, source, source_branch, target_branch, reviewed_sha,
 effort, max_lines, max_files, n_all, n_kept, invariants, invariants_reason,
 worktree_sha, self_dir, deleted_path) = sys.argv[1:18]
max_lines, max_files = int(max_lines), int(max_files)

# ONE definition of "is this a test path", in pipeline/testpaths.py. There were two here, 188 lines
# apart, and they disagreed by `e2e/` and `.test.<ext>` — see that module's docstring. The import
# DIES rather than falling back to a local regex: a review context built on a guessed predicate is
# worse than no review context, because it looks complete.
sys.path.insert(0, self_dir)
try:
    from testpaths import is_doc_path, is_test_path, non_test_source
except ImportError as exc:
    print(f"prepare-context: cannot import testpaths from {self_dir}: {exc}", file=sys.stderr)
    print("  That is an ERROR, not a skip. If this pipeline was vendored elsewhere, "
          "pipeline/testpaths.py must be vendored with it.", file=sys.stderr)
    sys.exit(1)

with open(changed_path) as fh:
    files = [ln.strip() for ln in fh if ln.strip()]
# Deleted files are in the diff but in no gate: nothing was added to test, and there is no new file
# to judge. They are listed separately in CONTEXT.json and their hunks go into DIFF.md.
with open(deleted_path) as fh:
    deleted = [ln.strip() for ln in fh if ln.strip()]

# ----------------------------------------------------------------- stack signals
# Same case arms as review-scan.sh's stack detection. Kept as suffix tuples rather than one
# regex so a reader can see at a glance which extension lands in which bucket.
def sig(exts):
    return any(f.endswith(exts) for f in files)

signals = {
    "code": sig((".py", ".ts", ".tsx", ".js", ".jsx", ".go", ".rb", ".java", ".rs", ".php", ".cs")),
    "iac": sig((".tf", ".tfvars", ".hcl")),
    "shell": sig((".sh", ".bash", ".zsh")),
    "web": sig((".ts", ".tsx", ".js", ".jsx", ".mjs")),
    "tests": any(is_test_path(f) for f in files),
    "migration": any(re.search(r"(^|/)(migrations?|alembic)/|\.sql$", f) for f in files),
    "docs_only": bool(files) and all(f.endswith((".md", ".markdown", ".rst", ".txt")) for f in files),
}

# ----------------------------------------------------------------- diff assembly
# quotePath=false so `+++ b/<path>` carries the real name rather than a C-quoted one, and literal
# pathspecs so a file named `[ab].py` is not read as a glob that also matches `a.py`.
GIT = ["git", "-c", "core.quotePath=false", "--literal-pathspecs"]
# ONE git invocation per 200 files (a batch size that stays far below ARG_MAX even for long paths)
# rather than one per file: on a 40-file change that is 39 fewer
# processes, and the per-file split below is exact because `diff --git` starts every file section.
def run_diff(paths):
    if not paths:
        return ""
    cmd = GIT + ["diff", "-U3", "--no-color", f"{base}...{source}", "--"] + paths
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout
    except OSError:
        return ""

diff_paths = files + deleted
raw = "".join(run_diff(diff_paths[i:i + 200]) for i in range(0, len(diff_paths), 200))

# Split on the `diff --git` header. `re.split` with a capturing group keeps the header itself, and
# a leading empty element appears when the output starts with a header — drop it.
parts = re.split(r"(?m)^(?=diff --git )", raw)
# Per-line byte cap. The per-file/global caps below bound LINE COUNT, so a single line that is
# itself huge — a regenerated one-line SVG diff, a minified bundle, a lockfile-shaped blob — sails
# through untouched: a 40-line file can still be a 4MB DIFF.md. Truncate the line's tail IN PLACE
# (never drop the line) so line count and ordering, which downstream line anchors depend on, are
# unaffected by this cap.
# 1200 characters is about fifteen 80-column lines: long enough for any hand-written code line, short
# enough that one minified line cannot cost more than a small file.
LINE_BYTE_CAP = 1200

def cap_line(line):
    if len(line) <= LINE_BYTE_CAP:
        return line, False
    return line[:LINE_BYTE_CAP] + f" ... [TRUNCATED: line was {len(line)} chars]", True

chunks = []
lines_byte_truncated = []
for part in parts:
    if not part.startswith("diff --git "):
        continue
    # `\t?` because git appends a TAB to the ---/+++ name when the path contains a space, and the
    # TAB is not part of the name. `+++ /dev/null` (a deleted file) falls through to the header.
    m = re.search(r"(?m)^\+\+\+ b/(.+?)\t?$", part)
    path = m.group(1) if m else None
    if path is None:
        m = re.match(r'diff --git a/(?:.+) b/(.+)', part)
        path = m.group(1).strip() if m else "(unknown)"
    raw_lines = part.rstrip("\n").split("\n")
    capped_lines, n_capped = [], 0
    for ln in raw_lines:
        out_ln, was_capped = cap_line(ln)
        capped_lines.append(out_ln)
        n_capped += was_capped
    if n_capped:
        lines_byte_truncated.append({"path": path, "count": n_capped})
    chunks.append((path, capped_lines))


# Spend the budget on source before prose. A change that touches 14 markdown files and 10 Python
# files would otherwise give the Python 62 lines each, and a semantic reviewer cannot find a
# business-logic error in 62 lines of a 400-line diff. Stable sort, so git's own ordering is
# preserved inside each class and two runs of the same diff produce byte-identical DIFF.md.
def priority(path):
    if path.endswith((".md", ".markdown", ".rst", ".txt")):
        return 2
    if path.endswith((".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".lock")):
        return 1
    return 0

chunks.sort(key=lambda c: priority(c[0]))

included, omitted, truncated = [], [], []
budget = max_lines
# A per-file cap, not just a global one. With a global cap alone the first huge file eats the whole
# budget and every later file is omitted entirely — so the reviewer never sees 39 of 40 files. The
# floor of 60 lines keeps small files whole even when the change is wide.
#
# The primary cap is divided among SOURCE files only. Config and prose get a flat, smaller cap so
# they cannot dilute it; when a change has no source files at all they become the primary class, so
# a docs-only change still gets a full-size budget per file.
primary = [c for c in chunks if priority(c[0]) == 0] or chunks
per_file = max(60, max_lines // max(1, min(len(primary), max_files)))
# Config and prose files get a flat 40 lines: enough to show a manifest or a doc edit in context,
# small enough that they cannot crowd the source files out of the budget.
SECONDARY_CAP = 40
primary_paths = set(p for p, _ in primary)

# The 60-line floor fights the global budget: at --max-diff-lines 300 over 6 files the floor hands
# out 60 × 5 = 300 and the sixth file is omitted entirely — reintroducing the very starvation the
# per-file cap exists to prevent. So reserve MIN_SLICE lines for every file still to come before
# spending on this one. Each file is guaranteed a look-in; the tail gets a short one.
# 12 lines is one -U3 hunk with a few changed lines: the least that still shows what a file's change is.
MIN_SLICE = 12
eligible, over = chunks[:max_files], chunks[max_files:]

body = []
for i, (path, lines) in enumerate(eligible):
    if budget <= 0:
        omitted.append(path)
        continue
    reserve = MIN_SLICE * (len(eligible) - i - 1)
    allowance = max(MIN_SLICE, budget - reserve)
    cap = per_file if path in primary_paths else SECONDARY_CAP
    keep = lines[:min(cap, allowance, budget)]
    was_cut = len(keep) < len(lines)
    budget -= len(keep)
    included.append(path)
    if was_cut:
        truncated.append(path)
    body.append(f"### `{path}`\n")
    body.append("```diff")
    body.extend(keep)
    if was_cut:
        body.append(f"... [{len(lines) - len(keep)} more diff line(s) omitted — "
                    f"read the file directly if a finding depends on them]")
    body.append("```\n")

omitted.extend(p for p, _ in over)

stat = subprocess.run(GIT + ["diff", "--stat", f"{base}...{source}"],
                      capture_output=True, text=True, check=False).stdout.rstrip("\n")

head = [
    "# Diff under review\n",
    f"- Base: `{base}` → source: `{source}` @ `{reviewed_sha[:12]}`",
    f"- Files: {n_kept} of {n_all} changed (generated files excluded)"
    + (f", {len(deleted)} deleted" if deleted else ""),
    f"- Diff budget: {max_lines - budget} of {max_lines} lines, {len(included)} of {len(chunks)} files\n",
    "```", stat, "```\n",
]
if omitted:
    head.append("**Files whose diff is NOT below** (budget exhausted): " +
                ", ".join(f"`{p}`" for p in omitted) + "\n")
if truncated:
    head.append("**Files whose diff is truncated:** " + ", ".join(f"`{p}`" for p in truncated) + "\n")

with open(os.path.join(out_dir, "DIFF.md"), "w") as fh:
    fh.write("\n".join(head + body))

# ----------------------------------------------------------------- architect gate
# Deterministic, and every arm records its own reason. The legacy gate was a sentence in the
# architect's prompt telling it to scope its own sweeps; this decides before the agent exists.
SCHEMA_SURFACE = re.compile(
    r"(^|/)(models\.py|schema\.[a-z]+)$|\.prisma$|\.sql$|(^|/)(migrations?|alembic)/")
MANIFEST = re.compile(
    r"(^|/)(plugin\.json|package\.json|pyproject\.toml|requirements\.txt|go\.mod|Cargo\.toml)$")
NEW_MODULE = re.compile(r"(^|/)(__init__\.py|index\.ts|index\.tsx|mod\.rs)$")
# A manifest whose ONLY changed line is its version number is not an architectural event. A repo
# that mandates a version bump on every plugin edit makes filename-only matching spawn the opus
# architect on every single change — the exact unbounded cost this rearchitecture exists to remove.
VERSION_ONLY = re.compile(r'^[+-]\s*"?version"?\s*[:=]')

# -z and a NUL split, NOT .split(): whitespace-splitting turned `new dir/__init__.py` into two
# bogus names and hid the new module entry point from the gate.
added = [p for p in subprocess.run(
    GIT + ["diff", "--name-only", "-z", "--diff-filter=A", f"{base}...{source}"],
    capture_output=True, text=True, check=False).stdout.split("\0") if p]

def manifest_is_substantive(paths):
    """True when a manifest diff changes anything beyond its version field."""
    if not paths:
        return []
    out = subprocess.run(GIT + ["diff", "-U0", "--no-color", f"{base}...{source}", "--"] + paths,
                         capture_output=True, text=True, check=False).stdout
    current, substantive = None, []
    for line in out.split("\n"):
        m = re.match(r"^\+\+\+ b/(.+?)\t?$", line)
        if m:
            current = m.group(1)
            continue
        if not line[:1] in ("+", "-") or line.startswith(("+++", "---")):
            continue
        if VERSION_ONLY.match(line):
            continue
        if current and current not in substantive:
            substantive.append(current)
    return substantive

reasons = []
if signals["iac"] or any(f.startswith("infrastructure/") or f.startswith("terraform/") for f in files):
    reasons.append("infrastructure/IaC in the diff")
if [f for f in added if NEW_MODULE.search(f)]:
    reasons.append("new module entry point added")
schema_hits = [f for f in files if SCHEMA_SURFACE.search(f)]
if schema_hits:
    reasons.append(f"schema/migration surface touched ({', '.join(schema_hits[:3])})")
manifest_hits = manifest_is_substantive([f for f in files if MANIFEST.search(f)])
if manifest_hits:
    reasons.append(f"dependency manifest changed beyond its version ({', '.join(manifest_hits[:3])})")
# 25 files is a judgement call, not a measurement: past it a change is usually cross-cutting enough
# that a design read pays for itself even with no single architectural signal above.
ARCHITECT_FILE_THRESHOLD = 25
if len(files) > ARCHITECT_FILE_THRESHOLD:
    reasons.append(f"{len(files)} changed files exceeds the {ARCHITECT_FILE_THRESHOLD}-file "
                   "design-review threshold")

if effort == "low":
    architect = {"spawn": False, "reason": "--effort low never spawns the architect"}
elif effort == "high":
    architect = {"spawn": True, "reason": "--effort high always spawns the architect"
                 + (f"; also: {reasons[0]}" if reasons else "")}
elif signals["docs_only"]:
    architect = {"spawn": False, "reason": "docs-only change"}
elif reasons:
    architect = {"spawn": True, "reason": "; ".join(reasons)}
else:
    architect = {"spawn": False, "reason": "no architectural surface in the diff, "
                 f"{ARCHITECT_FILE_THRESHOLD} files or fewer"}

# ------------------------------------------------------------------- testing gate
# Deterministic like the architect gate, and for the same reason: the previous
# arrangement was a LENS inside review-semantic, i.e. a sentence asking one generalist pass to
# also judge test adequacy. That was measured and lost — three rounds on one measured change found
# no test finding, and the arm with a dedicated testing specialist then returned a blocking MAJOR on
# the same branch (a new gate path missing from an existing parity parametrization).
#
# The gate is deliberately broad: ANY changed non-test source file can introduce behaviour that
# needs a test, so the interesting question is not "is this diff testable" but "did it change
# behaviour at all". Docs-only and test-only diffs are the two real exclusions.
#
# A test-only diff is excluded because there is no new production behaviour to judge tests AGAINST —
# the lens is "do the tests match the diff's new behaviours", which is vacuous when the diff adds no
# behaviour. Semantic still reviews such a diff.
#
# The predicate is pipeline/testpaths.py's, imported at the top of this block. It USED to be a second
# local regex here, narrower than the one at signals["tests"] by `e2e/` and `.test.<ext>` — so
# `foo.test.ts` counted as production source and a diff of nothing but `*.test.ts` spawned the testing
# pass against the tests themselves. The union won; see that module's docstring.
nts = non_test_source(files)

if effort == "low":
    testing = {"spawn": False, "reason": "--effort low never spawns the testing pass"}
elif signals["docs_only"]:
    testing = {"spawn": False, "reason": "docs-only change"}
elif not nts:
    # Name what the diff actually WAS. An inaccurate skip reason is the thing this gate's
    # record-the-reason design exists to prevent: "test-only diff" printed over a docs-only diff
    # sends the next reader looking for tests that were never in it.
    kinds = []
    if [f for f in files if is_test_path(f)]:
        kinds.append("tests")
    if [f for f in files if is_doc_path(f)]:
        kinds.append("docs")
    if not files and deleted:
        reason = (f"deletion-only diff ({len(deleted)} file(s) deleted): no new behaviour to test; "
                  "the deletions are in DIFF.md")
    elif not files:
        reason = "empty diff: nothing to review"
    else:
        reason = (f"{'/'.join(kinds)}-only diff: no new production behaviour to judge the tests "
                  "against")
    testing = {"spawn": False, "reason": reason}
else:
    testing = {"spawn": True,
               "reason": f"{len(nts)} non-test source file(s) changed "
                         f"({', '.join(nts[:3])}"
                         f"{', …' if len(nts) > 3 else ''})"}

# ----------------------------------------------------------- claude-config gate
# No existing signal detects changes to Claude Code's own authoring surface (SKILL.md,
# agents/*.md, plugin.json, hooks). Those are not application code, so ordinary review does not
# judge them against the Agent Skills open standard or the repo's own structural invariants — see
# the skill-and-plugin-authoring skill for the checklist review-authoring-conformance reads.
#
# Deliberately does NOT skip on signals["docs_only"], unlike the testing gate above. SKILL.md and
# agents/*.md are themselves markdown, so a diff touching only them IS a docs_only diff by that
# signal's definition — and it is exactly the case this gate exists to catch. Skipping on docs_only
# here would silently disable the gate for its own primary target.
CLAUDE_CONFIG_SURFACE = re.compile(
    r"(^|/)SKILL\.md$|(^|/)agents/.+\.md$|(^|/)\.claude-plugin/plugin\.json$|(^|/)hooks/.*\.(json|sh)$")

cfg_hits = [f for f in files if CLAUDE_CONFIG_SURFACE.search(f)]

if effort == "low":
    claude_config = {"spawn": False, "reason": "--effort low never spawns the claude-config pass"}
elif not cfg_hits:
    claude_config = {"spawn": False,
                      "reason": "no SKILL.md, agents/*.md, plugin.json, or hooks file in the diff"}
else:
    claude_config = {"spawn": True,
                      "reason": f"{len(cfg_hits)} Claude Code authoring file(s) changed "
                                f"({', '.join(cfg_hits[:3])}"
                                f"{', …' if len(cfg_hits) > 3 else ''})"}

# ----------------------------------------------------------------- scan metrics
scan = {"present": False}
scan_path = os.path.join(out_dir, "SCAN.json")
try:
    with open(scan_path) as fh:
        doc = json.load(fh)
    meta = doc.get("scan_meta") or {}
    scan = {
        "present": True,
        "path": scan_path,
        "verdict": doc.get("verdict"),
        "metrics": doc.get("metrics") or {},
        "diff_scoped": meta.get("diff_scoped"),
        "tools_run": meta.get("tools_run") or [],
        "tools_skipped": [s.get("tool") for s in (meta.get("tools_skipped") or [])],
    }
except (OSError, ValueError):
    # No scan, or an unreadable one. Recorded as absent so the verdict can say the deterministic
    # pass did not happen instead of implying it came back clean.
    pass

context = {
    "source_branch": source_branch,
    "target_branch": target_branch,
    "base_ref": base,
    "source_ref": source,
    "reviewed_sha": reviewed_sha,
    # Whether Read/Grep on a repository file returns the code that was actually diffed. False means
    # the reviewed ref is not checked out: DIFF.md is still authoritative, but the working tree is a
    # different commit, so no agent may cite a line it read from disk as the reviewed code.
    "worktree": {
        "head_sha": worktree_sha or None,
        "matches_reviewed_ref": bool(worktree_sha) and worktree_sha == reviewed_sha,
    },
    "diff_range": f"{base}...{source}",
    "effort": effort,
    "changed_files": files,
    "changed_file_count": len(files),
    "deleted_files": deleted,
    "generated_excluded": int(n_all) - int(n_kept),
    "signals": signals,
    "diff": {
        "path": os.path.join(out_dir, "DIFF.md"),
        "lines_included": max_lines - budget,
        "line_budget": max_lines,
        "files_included": included,
        "files_truncated": truncated,
        "files_omitted": omitted,
        # Distinct from files_truncated: a file can have EVERY one of its lines included
        # (files_truncated empty for it) while one of those lines was itself byte-capped by
        # LINE_BYTE_CAP above. The two markers can both fire on the same file — a byte-truncated
        # line renders inline where it sits; the omitted-lines summary is appended after the
        # file's body — and are visually distinct so a reader never confuses one for the other.
        "lines_byte_truncated": lines_byte_truncated,
    },
    "architect": architect,
    "testing": testing,
    "claude_config": claude_config,
    # Null means the agents are NOT told the file exists. `invariants_reason` says which of the two
    # nulls this is: no file at all, or a file refused for exceeding the advertise cap. Never infer
    # "the repo has no invariants" from the path alone.
    "invariants_path": invariants or None,
    "invariants_reason": invariants_reason,
    "scan": scan,
}
with open(os.path.join(out_dir, "CONTEXT.json"), "w") as fh:
    json.dump(context, fh, indent=2)

print(f"context: {len(files)} file(s), {max_lines - budget} diff line(s), "
      f"architect={'spawn' if architect['spawn'] else 'skip'} ({architect['reason']}), "
      f"testing={'spawn' if testing['spawn'] else 'skip'} ({testing['reason']})")
if not context["worktree"]["matches_reviewed_ref"]:
    print(f"context: WARN — the working tree is at {(worktree_sha or '?')[:12]} but the reviewed ref "
          f"{source} is {reviewed_sha[:12]}. DIFF.md is correct; file reads are NOT the reviewed "
          f"code. Check the ref out, or expect findings anchored on the wrong lines.")
if lines_byte_truncated:
    total_capped = sum(e["count"] for e in lines_byte_truncated)
    print(f"context: WARN — {total_capped} oversized diff line(s) across "
          f"{len(lines_byte_truncated)} file(s) were byte-truncated (LINE_BYTE_CAP="
          f"{LINE_BYTE_CAP}); see CONTEXT.json.diff.lines_byte_truncated. Those lines are UNREAD "
          f"past the cap, not clean.")
PY
rc=$?
[ "$rc" -eq 0 ] || die "could not build the review context (python3 exited $rc)"

say "prepare-context: wrote $OUT/CONTEXT.json and $OUT/DIFF.md"
exit 0
