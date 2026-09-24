#!/usr/bin/env bash
# comments.test.sh — the comment detector's own arms, below the generic contract.
#
#   bash pipeline/detectors/comments.test.sh
#   zsh  pipeline/detectors/comments.test.sh
#
# `detectors.test.sh` asserts the CONTRACT every detector shares. This file asserts the two things
# only `comments.sh` can be wrong about, and it is weighted heavily towards the second:
#
#   1. Each rule fires on a planted defect — a block of commented-out code, a marker with nothing
#      tracking it.
#   2. NOTHING fires on ordinary prose. This is where a comment detector lives or dies. Comments are
#      everywhere, a reader cannot tell a bad hit from a good one without opening each file, and one
#      noisy run teaches them to ignore the rule id forever. Every negative fixture below is a real
#      shape from real code — a licence header, a `# noqa` stack, a docstring-style explanation
#      containing an example, a tracked TODO — chosen because each is a plausible way for a naive
#      pattern to fire.
#
# Both rules emit NIT, which is asserted rather than assumed: they are a shortlist for a human, and
# a regression that promoted them would start blocking merges over a stale comment.
#
# Every fixture is built under $TMP and removed by the trap. No repository is touched, no network.
#
# Portable bash 3.2+ / zsh.

set -uo pipefail
# No __pycache__ left in the plugin tree: the suites import normalize/contract/testpaths in place.
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DET="$SELF_DIR/comments.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/comments-detector-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

printf 'comments detector tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

if [ ! -f "$DET" ]; then
  fail "detectors/comments.sh exists" "not found at $DET"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

if ! have python3; then
  skipt "every comments.sh rule assertion" "python3 is not installed; the detector records its own skip"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

t="detectors/comments.sh is executable"
if [ -x "$DET" ]; then pass "$t"; else fail "$t" "the executable bit is not set"; fi

CASE=0

run() {
  CASE=$((CASE + 1))
  local wt="$1" od="$TMP/out-$CASE"
  mkdir -p "$od"
  ( cd "$wt" && bash "$DET" "$wt/.changed" "$od" ) >"$od.stdout" 2>"$od.stderr"
  printf '%s\n' "$od"
}

report() {
  python3 - "$1/raw/comments.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit
for f in d.get("findings") or []:
    print(f"{f.get('rule')}:{f.get('severity')}")
PY
}

expect_hit() {
  local label="$1" wt="$2" want="$3" od got
  od="$(run "$wt")"
  got="$(report "$od" | tr '\n' ' ')"
  case " $got " in
    *" $want "*) pass "$label" ;;
    *) fail "$label" "expected a '$want' finding, got: ${got:-<none>}" ;;
  esac
}

expect_clean() {
  local label="$1" wt="$2" od got
  od="$(run "$wt")"
  got="$(report "$od" | tr '\n' ' ')"
  if [ -z "${got// /}" ]; then
    pass "$label"
  else
    fail "$label" "ordinary code produced: $got"
  fi
}

fixture() {
  local d="$TMP/$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/.changed"
  printf '%s\n' "$d"
}

# ================================================================ commented-out code
d="$(fixture dead-py mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    return process(event)

# def old_handler(event):
#     payload = json.loads(event["body"])
#     return process(payload)
PY
expect_hit "a block of commented-out Python is reported as NIT" "$d" "commented-out-code:NIT"

d="$(fixture dead-ts app.ts)"
cat > "$d/app.ts" <<'TS'
export function render(x: number) {
  return x * 2;
}

// const cache = new Map();
// cache.set("a", 1);
// return cache.get("a");
TS
expect_hit "a block of commented-out TypeScript is reported as NIT" "$d" "commented-out-code:NIT"

t="two commented-out lines are NOT reported"
# The MIN_BLOCK threshold, asserted directly. Two lines is as likely to be a two-line explanation as
# a deletion, and the detector deliberately declines to guess.
d="$(fixture dead-short mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # x = 1
    # y = 2
    return event
PY
expect_clean "$t" "$d"

t="a prose line inside a run breaks it"
# The rule requires EVERY line in the run to read as code. A comment that explains something and
# happens to include a code example is the single most common false positive available, and this is
# the fixture that proves it is excluded.
d="$(fixture dead-prose mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # The upstream API returns the body already decoded, so the call is:
    #     process(event["body"])
    # which is why there is no json.loads here.
    return process(event["body"])
PY
expect_clean "$t" "$d"

t="a licence header and a stack of tool directives are not dead code"
d="$(fixture directives mod.py)"
cat > "$d/mod.py" <<'PY'
#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright 2026 Example Ltd
# type: ignore
# noqa: E501
# pylint: disable=too-many-locals
# ruff: noqa
import os
print(os.getcwd())
PY
expect_clean "$t" "$d"

# ================================================================ untracked markers
d="$(fixture marker-bare mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # TODO: retry when the upstream rate-limits
    return process(event)
PY
expect_hit "a bare TODO is reported as NIT" "$d" "untracked-marker:NIT"

d="$(fixture marker-owner mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # TODO(alice): retry when the upstream rate-limits
    return process(event)
PY
expect_hit "a TODO carrying only an owner name is still untracked" "$d" "untracked-marker:NIT"

d="$(fixture marker-trailing app.ts)"
printf 'const x = compute();  // FIXME rounding is wrong at the boundary\n' > "$d/app.ts"
expect_hit "a trailing FIXME with no reference is reported" "$d" "untracked-marker:NIT"

t="a marker carrying an issue number, a tracker key or a URL is not reported"
d="$(fixture marker-tracked mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # TODO(#412): retry when the upstream rate-limits
    # FIXME PROJ-1187 the boundary rounding is wrong
    # XXX: works around the upstream bug, see
    # https://github.com/example/lib/issues/91
    return process(event)
PY
expect_clean "$t" "$d"

t="a sentence that merely mentions a marker is not a marker"
# The anchor. An unanchored search fires on every standards document and every code comment that
# discusses the rule — including this detector's own source, which is a .sh file the scanner reads.
d="$(fixture marker-prose mod.py)"
cat > "$d/mod.py" <<'PY'
def handler(event):
    # We used to leave a TODO here; the rule now says file an issue instead.
    return process(event)
PY
expect_clean "$t" "$d"

# ================================================================ selection
t="a Markdown file is not scanned for comments"
# `#` in Markdown is a heading, not a comment. Scanning it would make every document in the change
# a source of findings about its own prose.
d="$(fixture md NOTES.md)"
cat > "$d/NOTES.md" <<'MD'
# TODO list

- x = 1
- y = 2
MD
od="$(run "$d")"
if [ -f "$od/raw/comments.skipped" ] && grep -q 'comment syntax' "$od/raw/comments.skipped"; then
  pass "$t"
else
  fail "$t" "skip record: $(cat "$od/raw/comments.skipped" 2>/dev/null || printf '<none>')"
fi

t="a clean source file with ordinary comments produces nothing at all"
# The shape most files in most changes actually have. If this one is not silent, the detector is a
# tax on every review rather than a signal in some of them.
d="$(fixture ordinary mod.py)"
cat > "$d/mod.py" <<'PY'
import json


def handler(event):
    """Decode and process one event."""
    # The upstream sends the body pre-decoded on the v2 endpoint only; v1 callers still
    # send a JSON string, and both are in production until the migration finishes.
    body = event["body"]
    if isinstance(body, str):
        body = json.loads(body)
    return process(body)
PY
expect_clean "$t" "$d"

t="the scratch file list is cleaned up"
leftover=""
for od in "$TMP"/out-*; do
  [ -d "$od/raw" ] || continue
  [ -f "$od/raw/.comment-files" ] && leftover="$leftover ${od##*/}/.comment-files"
done
if [ -z "$leftover" ]; then pass "$t"; else fail "$t" "survived:$leftover"; fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
