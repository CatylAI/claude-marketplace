#!/usr/bin/env bash
# _lib.test.sh — the rejection paths of require_safe_out(), and the two entry points that depend on it.
#
#   bash pipeline/_lib.test.sh        # run everything
#   zsh  pipeline/_lib.test.sh        # the portability half of the contract
#
# WHY THIS SUITE EXISTS. `require_safe_out` lives in `_lib.sh` precisely because it is a security
# check, and "a security check duplicated across two files is two things to keep correct" — its own
# words. A function whose entire purpose is refusal needs proof that it still refuses; a happy-path
# suite (the fence gets written, it applies recursively, a user edit survives) proves the opposite
# property and would stay green if the guard were deleted outright.
#
# The blast radius, in the file's own words: the fence writes a `.gitignore` containing `*` into
# whatever `--out` names, and `*` at a REPO ROOT makes git ignore the entire working tree. So the two
# assertions per integration case are both load-bearing — a non-zero exit AND no `.gitignore`
# written. A guard that returns 1 after the write has already happened is not a guard.
#
# Nothing is touched outside $TMP_ROOT, which the trap removes on any exit.
#
# Portable bash 3.2+ / zsh, like the code it tests.

set -uo pipefail
# No __pycache__ left in the plugin tree: the suites import normalize/contract/testpaths in place.
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0; FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/code-review-lib-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

printf '_lib tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

# --- Unit: every branch of require_safe_out --------------------------------------------------------
# Sourced in a subshell per case so a `return 1` cannot leak state between cases.

check_reject() { # <label> <value>
  label="$1"; val="${2-}"
  out="$( ( . "$SELF_DIR/_lib.sh"; require_safe_out "$val" ) 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -q 'refusing --out'; then
      pass "$label"
    else
      fail "$label — rejected (rc=$rc) but printed no 'refusing --out' reason: $out"
    fi
  else
    fail "$label — ACCEPTED a typo-shaped value (rc=0)"
  fi
}

check_accept() { # <label> <value>
  label="$1"; val="$2"
  ( . "$SELF_DIR/_lib.sh"; require_safe_out "$val" ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then pass "$label"; else fail "$label — REJECTED a legitimate value (rc=$rc)"; fi
}

# The four literals in the first case arm, each named individually. A single representative would
# leave the other three able to rot: the arm is an alternation, so one branch working proves nothing
# about the rest.
check_reject "the empty string is refused"        ""
check_reject "'.' is refused"                     "."
check_reject "'./' is refused"                    "./"
check_reject "'/' is refused"                     "/"

# require_safe_out with NO argument at all — the `${1-}` default. A caller whose variable is unset
# under `set -u` must still be refused rather than crashing or passing.
if out="$( ( . "$SELF_DIR/_lib.sh"; require_safe_out ) 2>&1 )"; then
  fail "a MISSING argument was accepted (rc=0)"
else
  if printf '%s' "$out" | grep -q 'refusing --out'; then
    pass "a missing argument is refused, not crashed on"
  else
    fail "a missing argument produced no refusal message: $out"
  fi
fi

# The `*..*` arm, in each position the glob has to cover.
check_reject "a bare '..' is refused"                    ".."
check_reject "a leading '../' is refused"                "../elsewhere"
check_reject "an EMBEDDED '..' is refused"               "a/../../etc"
check_reject "a trailing '..' is refused"                "sub/.."
check_reject "'..' inside an absolute path is refused"   "/tmp/x/../y"

# The values every real caller passes. If these regress, every review stops running — so the
# false-positive direction is as important as the rejection direction.
check_accept "'.code-review' (the review caller) is accepted"   ".code-review"
check_accept "'.orchestration' (the other caller) is accepted"  ".orchestration"
check_accept "a nested relative path is accepted"               "build/artifacts"
# Deliberately accepted per the guard's own documentation: an absolute --out is NOT restricted to the
# repo, because comparing unresolved path prefixes broke a valid "$TMPDIR/repo/.code-review" on macOS
# where /var is a symlink to /private/var. Asserted so the removal stays a decision, not a gap.
check_accept "an absolute path outside the repo is accepted (documented, deliberate)" "$TMP_ROOT/x/.code-review"
# Also deliberately accepted, and the guard says so: this is a typo guard, not validation. Asserting
# it keeps the limitation honest rather than letting a reader assume protection that is not there.
check_accept "'src' is accepted — a typo guard is not validation (documented limitation)" "src"

# A single dot is refused but a dotted NAME must not be: `*..*` glob greediness is the kind of thing
# that turns a guard into an outage.
check_accept "a dotfile-style name is accepted"           ".code-review.old"
check_accept "a name containing a single dot is accepted" "out.d"

# --- Integration: the guard actually fires BEFORE the fence is written -----------------------------
# The unit tests prove the function refuses. These prove the CALLERS refuse — and, critically, that
# nothing was written on the way out. review-scan.sh and prepare-context.sh each source _lib.sh and
# `die` on a non-zero return; a guard placed after the mkdir/fence would still pass the unit tests.

for script in review-scan.sh prepare-context.sh; do
  if [ ! -f "$SELF_DIR/$script" ]; then
    fail "$script not found — cannot integration-test the guard"
    continue
  fi
  # Numbered, not name-derived: `./` and `..` both sanitise to the same string, so a name-derived
  # directory would silently make the second case reuse the first case's repo.
  n=0
  for bad in "." "./" ".." "a/../../etc"; do
    n=$((n + 1))
    W="$TMP_ROOT/int-$script-$n"
    mkdir -p "$W"
    git -C "$W" init -q 2>/dev/null
    git -C "$W" config user.email t@example.com 2>/dev/null
    git -C "$W" config user.name Test 2>/dev/null
    git -C "$W" config commit.gpgsign false 2>/dev/null
    printf 'seed\n' > "$W/README.md"
    git -C "$W" add -A >/dev/null 2>&1
    git -C "$W" commit -q -m seed >/dev/null 2>&1
    ( cd "$W" && bash "$SELF_DIR/$script" --base HEAD --out "$bad" ) >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      fail "$script accepted --out '$bad' (rc=0)"
    else
      # No repo-blinding fence may exist at the root, whatever else the script did on its way out.
      if [ -f "$W/.gitignore" ] && grep -qx '\*' "$W/.gitignore" 2>/dev/null; then
        fail "$script refused --out '$bad' (rc=$rc) but had ALREADY written a '*' fence at the repo root"
      else
        pass "$script refuses --out '$bad' and writes no '*' fence"
      fi
    fi
  done
done

# A missing/unreadable _lib.sh must be a HARD FAILURE at both call sites, not a silently skipped
# guard — the file's own stated reason for being sourced with `|| die`.
#
# Asserted STATICALLY, and the reason is worth stating because a dynamic test would look stronger and
# be worse. Driving it dynamically means running each entry point with a _lib.sh removed, and both
# resolve `$SELF_DIR` from `$0` and parse arguments BEFORE the source line — so the run exits on arg
# validation first and "it failed" proves nothing about the source guard. What can actually regress
# here is someone dropping the `|| die`, turning a hard failure into a silently skipped security
# check, and a static assertion catches that precisely.
for script in review-scan.sh prepare-context.sh; do
  if [ ! -f "$SELF_DIR/$script" ]; then fail "$script not found"; continue; fi
  src_line="$(grep -nE '^\.[[:space:]]+"\$SELF_DIR/_lib\.sh"' "$SELF_DIR/$script" | head -1)"
  if [ -z "$src_line" ]; then
    fail "$script does not source _lib.sh at all — the guard is not in force"
  elif printf '%s' "$src_line" | grep -q '|| *die'; then
    pass "$script sources _lib.sh with '|| die' (a missing lib is a hard failure)"
  else
    fail "$script sources _lib.sh WITHOUT '|| die' — a missing lib silently skips the guard: $src_line"
  fi
  call_line="$(grep -nE 'require_safe_out[[:space:]]+"\$OUT"' "$SELF_DIR/$script" | head -1)"
  if [ -z "$call_line" ]; then
    fail "$script never calls require_safe_out on its \$OUT"
  elif printf '%s' "$call_line" | grep -q '|| *die'; then
    pass "$script calls require_safe_out with '|| die' (a refusal actually stops the run)"
  else
    fail "$script calls require_safe_out but ignores its return: $call_line"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
