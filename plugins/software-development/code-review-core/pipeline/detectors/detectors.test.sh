#!/usr/bin/env bash
# detectors.test.sh — THE DETECTOR CONTRACT, asserted against every detector on disk.
#
#   bash pipeline/detectors/detectors.test.sh
#   zsh  pipeline/detectors/detectors.test.sh
#
# The contract is stated in `_lib.sh` and is three lines long:
#
#   invocation : detectors/<name>.sh <changed-files-list-file> <outdir>
#   output     : <outdir>/raw/<tool>.json      — the tool's native JSON
#                <outdir>/raw/<tool>.skipped   — one line saying WHY, when it could not run
#   exit code  : ALWAYS 0
#
# WHY THIS SUITE EXISTS, AND WHY IT ITERATES. review-scan.test.sh drives the detectors through the
# scanner, so it can only see the arms whose binary happens to be installed on the machine running
# it — which on a machine with no `tflint` means the skip path is exercised and the run path is not,
# and on a CI image with everything installed means the reverse. Neither run asserts the CONTRACT,
# which is what review-scan.sh actually depends on: it dispatches a detector, ignores its exit code
# by design, and then believes raw/ completely. A detector that exits 2, or that writes nothing at
# all when its tool is absent, turns a coverage gap into a scan that reads as clean.
#
# Every case below iterates `detectors/*.sh` rather than naming five files, for the reason the rest
# of this pipeline gives for iterating its tables: a detector ADDED later is covered the moment it
# lands, instead of shipping with nobody noticing it was never in the list. `terraform.sh` shipped
# after this suite's siblings were written and needed no edit here.
#
# Everything happens inside $TMP, which the trap removes on any exit. No repository is touched.
#
# Portable bash 3.2+ / zsh.

set -uo pipefail

# Two zsh defaults this file relies on bash's behaviour for, and neither has a portable rewrite that
# stays readable: `for x in $LIST` (zsh does not word-split an unquoted expansion, so the whole list
# arrives as one word) and `for f in dir/*.glob` with no matches (zsh errors instead of leaving the
# pattern literal, which is how every `[ -e "$f" ] || continue` guard below is written). Opting into
# the sh behaviour is one line; threading a file-based list through nine loops is not. Guarded so
# bash never sees the zsh builtin.
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt sh_word_split no_nomatch 2>/dev/null || true
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/detector-contract-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

printf 'detector contract tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

# ---------------------------------------------------------------- the detector list
# Sourced from disk, never hardcoded. `_lib.sh` is excluded by name: it is sourced, never executed,
# and running it as a detector would assert a contract it does not claim to implement.
DETECTORS=""
for f in "$SELF_DIR"/*.sh; do
  [ -e "$f" ] || continue
  b="${f##*/}"
  case "$b" in _lib.sh|*.test.sh) continue ;; esac
  DETECTORS="$DETECTORS ${b%.sh}"
done

if [ -z "${DETECTORS# }" ]; then
  fail "there is at least one detector to test" "no detectors/*.sh found in $SELF_DIR"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi
printf '  detectors under test:%s\n' "$DETECTORS"

# ---------------------------------------------------------------- a PATH with no analysis tools
# The "missing binary" half of the contract cannot be tested by unsetting PATH: the detectors use
# `mkdir`, `grep`, `python3` and friends to do their own bookkeeping, so an empty PATH would make
# them fail for a reason that has nothing to do with the tool being absent — and the test would pass
# for the wrong reason, which is worse than not having it.
#
# So build a BARREN PATH instead: ordinary utilities symlinked in, every analysis tool deliberately
# left out. `need <tool>` then takes its not-found branch for real, with everything else working.
BARREN="$TMP/barren-bin"
mkdir -p "$BARREN"
for u in sh bash mkdir rmdir rm mv cp cat ls grep egrep sed awk head tail tr cut wc sort uniq \
         dirname basename find chmod date mktemp xargs tee env printf test expr git python3 python; do
  src="$(command -v "$u" 2>/dev/null)" || continue
  [ -n "$src" ] && ln -sf "$src" "$BARREN/$u" 2>/dev/null
done

# Guard the guard. If the barren PATH cannot run the utilities the detectors need, every case below
# would "pass" by failing early, so prove it is usable and prove it really hides the tools.
if ! ( PATH="$BARREN" command -v python3 >/dev/null 2>&1 && PATH="$BARREN" command -v grep >/dev/null 2>&1 ); then
  fail "the barren PATH is usable" "python3 or grep is missing from $BARREN"
else
  pass "the barren PATH still has python3 and grep (so a skip means 'tool absent', not 'shell broken')"
fi
hidden_ok=true
for tool in ruff bandit mypy pylint shellcheck gitleaks trivy terraform tflint checkov tfsec; do
  if PATH="$BARREN" command -v "$tool" >/dev/null 2>&1; then hidden_ok=false; fi
done
if $hidden_ok; then
  pass "the barren PATH hides every analysis tool (the missing-binary branch is genuinely taken)"
else
  fail "the barren PATH hides every analysis tool" "an analysis tool is still reachable from $BARREN"
fi

# ---------------------------------------------------------------- helpers
# A changed-file list covering EVERY extension any detector filters on, with the files really on
# disk — `filter_ext` drops entries that do not exist, so a list of names alone would make every
# detector take its "nothing to do" branch and no tool arm would ever be reached.
make_worktree() { # <dir>
  wt="$1"
  mkdir -p "$wt/infra" "$wt/src"
  printf 'def f():\n    try:\n        pass\n    except:\n        pass\n' > "$wt/src/mod.py"
  printf '#!/usr/bin/env bash\ncd /tmp\n' > "$wt/src/s.sh"
  printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "example-bucket"\n}\n' > "$wt/infra/main.tf"
  printf 'export const x = 1\n' > "$wt/src/app.ts"
  printf '# notes\n' > "$wt/README.md"
  ( cd "$wt" && printf '%s\n' src/mod.py src/s.sh infra/main.tf src/app.ts README.md ) > "$wt/.changed"
}

# Every detector is invoked from INSIDE the fixture worktree, because each resolves the paths in the
# list relative to the CWD — exactly as review-scan.sh calls it, having cd'd to the repo root first.
# The invocation is written out at each call site rather than wrapped, because the cases differ in
# which environment they need (a barren PATH here, SCAN_BASE there) and a wrapper taking both would
# hide the one variable each case is actually about.

# records <outdir> — how many contract records (json or skipped) exist under raw/.
records() { ls "$1/raw" 2>/dev/null | grep -cE '\.(json|skipped)$' 2>/dev/null || printf '0'; }

# ================================================================ 1. ALWAYS EXIT 0
# The single most important clause. review-scan.sh calls detectors with `|| true` as belt and
# braces, but prepare-context.sh and any future caller are entitled to rely on the contract itself,
# and a detector that exits non-zero on a machine missing one tool would abort a review over a
# coverage gap — the exact failure mode the always-zero rule exists to prevent.

# 1a. A normal invocation with real files, with the analysis tools HIDDEN.
for det in $DETECTORS; do
  wt="$TMP/exit0-$det"; make_worktree "$wt"
  od="$TMP/out-exit0-$det"; mkdir -p "$od"
  ( cd "$wt" && PATH="$BARREN" SCAN_BASE=HEAD SCAN_SOURCE=HEAD \
      bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$det.sh exits 0 with every analysis binary absent"
  else
    fail "$det.sh exits 0 with every analysis binary absent" "exited $rc"
  fi
done

# 1b. The degenerate inputs. A list file that does not exist, a list that is a DIRECTORY, and an
# empty list: none of them is a reason to fail a review, and all three are reachable (a caller
# passing the wrong path, an `--out` collision, a docs-only diff).
for det in $DETECTORS; do
  bad_rc=""
  od="$TMP/out-bad-$det"; mkdir -p "$od"
  bash "$SELF_DIR/$det.sh" /nonexistent/list "$od" >/dev/null 2>&1 || bad_rc="${bad_rc} missing-list=$?"
  mkdir -p "$TMP/a-directory"
  bash "$SELF_DIR/$det.sh" "$TMP/a-directory" "$od" >/dev/null 2>&1 || bad_rc="${bad_rc} list-is-a-dir=$?"
  : > "$TMP/empty-list"
  bash "$SELF_DIR/$det.sh" "$TMP/empty-list" "$od" >/dev/null 2>&1 || bad_rc="${bad_rc} empty-list=$?"
  if [ -z "$bad_rc" ]; then
    pass "$det.sh exits 0 on a missing, directory-shaped and empty file list"
  else
    fail "$det.sh exits 0 on a missing, directory-shaped and empty file list" "non-zero:$bad_rc"
  fi
done

# 1c. A list naming files that are IN the diff but no longer on disk — every deletion in every
# change. `filter_ext`'s `[ -f ]` test is what handles this; without it a detector hands a linter a
# path that does not exist and the linter's own error becomes the detector's exit code.
for det in $DETECTORS; do
  wt="$TMP/deleted-$det"; mkdir -p "$wt"
  ( cd "$wt" && printf '%s\n' gone.py gone.sh gone.tf gone.ts ) > "$wt/.changed"
  od="$TMP/out-deleted-$det"; mkdir -p "$od"
  ( cd "$wt" && SCAN_BASE=HEAD bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$det.sh exits 0 when every listed file has been deleted"
  else
    fail "$det.sh exits 0 when every listed file has been deleted" "exited $rc"
  fi
done

# ================================================================ 2. SILENCE IS NOT ALLOWED
# _lib.sh: "silence would be indistinguishable from a clean result, so every non-run writes a
# `.skipped` with a reason". This is the clause that makes SCAN-SUMMARY.md's coverage-gap section
# possible, and the one a reader's "no security findings" conclusion actually rests on.
for det in $DETECTORS; do
  t="$det.sh records a reason for every non-run, rather than writing nothing"
  wt="$TMP/silent-$det"; make_worktree "$wt"
  od="$TMP/out-silent-$det"; mkdir -p "$od"
  ( cd "$wt" && PATH="$BARREN" SCAN_BASE=HEAD SCAN_SOURCE=HEAD \
      bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) >/dev/null 2>&1
  n="$(records "$od")"
  if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "raw/ is empty — a skipped tool left no trace"; fi

  t="$det.sh's skip records are non-empty and each names a reason"
  blank=""
  for f in "$od"/raw/*.skipped; do
    [ -e "$f" ] || continue
    grep -q '[^[:space:]]' "$f" || blank="$blank ${f##*/}"
  done
  if [ -z "$blank" ]; then pass "$t"; else fail "$t" "empty .skipped file(s):$blank"; fi

  t="$det.sh invents no <tool>.json when the tool never ran"
  # The failure this catches is a detector that writes an empty `[]` on its way past a missing
  # binary: normalize.py would then count the tool in `tools_run`, and the scan would report
  # coverage it does not have.
  ghost=""
  for f in "$od"/raw/*.json; do
    [ -e "$f" ] || continue
    base="${f##*/}"; base="${base%.json}"
    [ -f "$od/raw/$base.skipped" ] && ghost="$ghost $base"
  done
  # terraform.sh is the one documented exception and says so at the call site: when `tflint` is
  # absent it PROMOTES the synthesised terraform-fmt document to raw/tflint.json so those findings
  # are not lost, and still records the skip. Both files are correct there.
  case "$det:$ghost" in
    terraform:" tflint") pass "$t (terraform's documented tflint-promote exception)" ;;
    *) if [ -z "$ghost" ]; then pass "$t"; else fail "$t" "both .json and .skipped for:$ghost"; fi ;;
  esac
done

# ================================================================ 3. THE OUTPUT LOCATION
# `<outdir>/raw/` — created by the detector, not assumed to exist. review-scan.sh does create it,
# but prepare-context.sh's `--skip-scan` path and any direct caller do not, and a detector that
# silently wrote nothing because `raw/` was missing would look exactly like a clean scan.
for det in $DETECTORS; do
  t="$det.sh creates <outdir>/raw itself"
  wt="$TMP/mkraw-$det"; make_worktree "$wt"
  od="$TMP/out-mkraw-$det"          # deliberately NOT created
  ( cd "$wt" && PATH="$BARREN" SCAN_BASE=HEAD SCAN_SOURCE=HEAD \
      bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) >/dev/null 2>&1
  if [ -d "$od/raw" ]; then pass "$t"; else fail "$t" "$od/raw was not created"; fi

  t="$det.sh writes nothing outside <outdir>"
  # A detector's scratch files (`.py-files`, `.tf-dirs`, `.ruff.err`) all belong under raw/ and are
  # cleaned up; none may land in the repository being reviewed. A stray file in the worktree would
  # show up as an untracked file in the change under review, which is how a review tool starts
  # producing findings about itself.
  stray="$(cd "$wt" && find . -type f ! -name '.changed' ! -name 'mod.py' ! -name 's.sh' \
             ! -name 'main.tf' ! -name 'app.ts' ! -name 'README.md' 2>/dev/null)"
  if [ -z "$stray" ]; then pass "$t"; else fail "$t" "left behind: $(printf '%s' "$stray" | tr '\n' ' ')"; fi
done

# ================================================================ 4. THE TOOL-NAMED SKIP
# `need <tool>` writes `raw/<tool>.skipped` with "binary not found on PATH". The TOOL NAME matters:
# SCAN-SUMMARY.md lists the skips by tool, so a skip recorded under the detector's name instead of
# the tool's would tell a reader "terraform was skipped" when what is actually missing is `tfsec`.
declare_tools() { # <detector> -> the tool names it is expected to account for
  case "$1" in
    python)    printf 'ruff bandit mypy pylint\n' ;;
    shell)     printf 'shellcheck\n' ;;
    secrets)   printf 'gitleaks trivy\n' ;;
    terraform) printf 'tflint checkov tfsec\n' ;;
    *)         printf '\n' ;;
  esac
}

for det in $DETECTORS; do
  tools="$(declare_tools "$det")"
  if [ -z "${tools# }" ]; then
    skipt "$det.sh names each absent tool in its own skip record" "no tool list declared for this detector"
    continue
  fi
  t="$det.sh names each absent tool in its own skip record"
  od="$TMP/out-silent-$det"   # reuse the barren-PATH run from section 2
  missing=""
  for tool in $tools; do
    if [ ! -f "$od/raw/$tool.skipped" ] && [ ! -f "$od/raw/$tool.json" ]; then
      missing="$missing $tool"
    fi
  done
  if [ -z "$missing" ]; then
    pass "$t"
  else
    fail "$t" "no record at all for:$missing (present: $(ls "$od/raw" 2>/dev/null | tr '\n' ' '))"
  fi

  t="$det.sh's missing-binary reason says the binary was not found"
  # The reason text is what a human reads in SCAN-SUMMARY.md. "skipped" with no cause is the same
  # silence the contract forbids, one level down.
  vague=""
  for tool in $tools; do
    [ -f "$od/raw/$tool.skipped" ] || continue
    grep -qi 'not found\|no output\|unparseable\|exited\|no .* in the diff\|not run' "$od/raw/$tool.skipped" \
      || vague="$vague $tool:$(head -1 "$od/raw/$tool.skipped")"
  done
  if [ -z "$vague" ]; then pass "$t"; else fail "$t" "uninformative reason(s):$vague"; fi
done

# ================================================================ 5. THE "NOTHING TO DO" BRANCH
# A detector handed only files it does not care about must record a skip explaining that — not run
# its tool with zero path arguments. `any_lines`'s comment is explicit about why: "running a linter
# with zero path arguments makes most of them scan the ENTIRE tree, which is exactly the unbounded
# cost being removed". This is asserted with the REAL PATH, so an installed tool could actually run
# away; the assertion is that it does not.
for det in $DETECTORS; do
  t="$det.sh does not run its tools on a diff containing none of its file types"
  wt="$TMP/nomatch-$det"; mkdir -p "$wt"
  printf 'just prose\n' > "$wt/NOTES.md"
  printf '%s\n' NOTES.md > "$wt/.changed"
  od="$TMP/out-nomatch-$det"; mkdir -p "$od"
  start=$(date +%s)
  ( cd "$wt" && SCAN_BASE=HEAD SCAN_SOURCE=HEAD bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) \
    >/dev/null 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  n_skipped=$(ls "$od/raw" 2>/dev/null | grep -c '\.skipped$' 2>/dev/null || printf '0')
  if [ "$rc" -ne 0 ]; then
    fail "$t" "exited $rc"
  elif [ "${n_skipped:-0}" -lt 1 ]; then
    fail "$t" "no skip recorded — the non-run is invisible"
  elif [ "$elapsed" -gt 30 ]; then
    fail "$t" "took ${elapsed}s — that is a whole-tree scan, not a no-op"
  else
    pass "$t"
  fi
done

# ================================================================ 6. THE IMPACT DETECTOR'S OWN GUARD
# impact.sh is the one detector that needs something outside the argv contract (the refs, via
# SCAN_BASE). It must refuse to GUESS a base rather than diffing against something arbitrary, and
# the refusal must be a recorded skip like any other.
if printf '%s' "$DETECTORS" | grep -q 'impact'; then
  t="impact.sh refuses to guess a base ref and records why"
  wt="$TMP/impact-nobase"; make_worktree "$wt"
  od="$TMP/out-impact-nobase"; mkdir -p "$od"
  ( cd "$wt" && unset SCAN_BASE; bash "$SELF_DIR/impact.sh" "$wt/.changed" "$od" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$od/raw/impact.skipped" ] \
     && grep -q 'SCAN_BASE' "$od/raw/impact.skipped"; then
    pass "$t"
  else
    fail "$t" "rc=$rc, skip record: $(cat "$od/raw/impact.skipped" 2>/dev/null || printf '<none>')"
  fi
else
  skipt "impact.sh refuses to guess a base ref" "impact.sh is not present"
fi

# ================================================================ 7. VALID JSON OR NO JSON
# normalize.py tolerates a malformed raw file by ignoring it — which means a detector that emits
# broken JSON loses its findings SILENTLY, with the tool still listed as having run. Whatever a
# detector does write must parse.
if have python3; then
  for det in $DETECTORS; do
    t="$det.sh's raw JSON parses (a malformed raw file loses its findings silently)"
    wt="$TMP/json-$det"; make_worktree "$wt"
    # A real git repo: impact.sh needs one, and the others are indifferent to it.
    git -C "$wt" init -q -b main >/dev/null 2>&1
    git -C "$wt" config user.email t@example.com >/dev/null 2>&1
    git -C "$wt" config user.name Test >/dev/null 2>&1
    git -C "$wt" config commit.gpgsign false >/dev/null 2>&1
    git -C "$wt" add -A >/dev/null 2>&1
    git -C "$wt" commit -q -m seed >/dev/null 2>&1
    od="$TMP/out-json-$det"; mkdir -p "$od"
    ( cd "$wt" && SCAN_BASE=HEAD SCAN_SOURCE=HEAD bash "$SELF_DIR/$det.sh" "$wt/.changed" "$od" ) \
      >/dev/null 2>&1
    bad=""
    for f in "$od"/raw/*.json; do
      [ -e "$f" ] || continue
      # mypy's raw output is JSONL by design (one object per line), so it is parsed line by line.
      case "${f##*/}" in
        mypy.json) python3 -c "
import json,sys
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if ln:
        json.loads(ln)" "$f" 2>/dev/null || bad="$bad ${f##*/}" ;;
        *) python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null \
             || bad="$bad ${f##*/}" ;;
      esac
    done
    if [ -z "$bad" ]; then pass "$t"; else fail "$t" "unparseable:$bad"; fi
  done
else
  skipt "raw JSON parse checks" "python3 not installed"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
