#!/usr/bin/env bash
# post-review.test.sh - the refusal paths of post-review.sh, and the routing it promises.
#
#   bash scripts/post-review.test.sh        # run everything
#   zsh  scripts/post-review.test.sh        # the portability half of the contract
#
# WHY THIS SUITE EXISTS. post-review.sh is mostly a refusal: it is the last thing between an
# unfinished review and a green check on a pull request. A happy-path suite - the payload is built,
# the inline comment lands - proves the opposite property and would stay green if every guard were
# deleted. So the cases that matter here PLANT A DEFECT AND ASSERT A NON-ZERO EXIT: no artifact, a
# truncated artifact, no jq, an empty document, a bad floor. A gate nobody has watched fail is an
# assumption, not a check.
#
# The second thing being asserted is that finding text is DATA. Findings are written by agents
# reading a diff, and a diff of a shell script contains command substitutions and backticks as a
# matter of course. One case feeds a title that would create a file if anything ever re-parsed it,
# and asserts the file does not appear.
#
# Nothing is touched outside $TMP_ROOT, which the trap removes on any exit. No network call is made:
# every case either runs --dry-run (which makes no gh call at all) or runs against a `gh` stub
# placed first on PATH.
#
# Portable bash 3.2+ / zsh, like the script it tests.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPT="$SELF_DIR/post-review.sh"

PASS=0; FAIL=0; SKIP=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/post-review-test.XXXXXX")"
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP %s\n' "$1"; }

printf 'post-review tests (shell: %s)\n' "${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION}"

if [ ! -f "$SCRIPT" ]; then
  printf '  FAIL post-review.sh not found at %s\n' "$SCRIPT"
  printf '\n0 passed, 1 failed, 0 skipped\n'
  exit 1
fi

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Absolute paths, resolved while PATH is still intact: the no-jq and no-gh cases run the script
# with a deliberately stripped PATH, and "bash: command not found" would fail the case for the
# wrong reason.
BASH_BIN="$(command -v bash)"
JQ_DIR=""
[ "$HAVE_JQ" -eq 1 ] && JQ_DIR="$(dirname "$(command -v jq)")"

# --- fixtures -------------------------------------------------------------------------------------
# Each case gets its own workspace so one case's artifacts cannot leak into the next.

new_ws() { # <name> -> prints the workspace path
  d="$TMP_ROOT/$1"
  mkdir -p "$d/.code-review"
  printf '%s' "$d"
}

# A document with one in-diff finding that has a parseable location, one pre-existing finding, and
# one whose location is prose. Covers all three routing outcomes in a single dry run.
write_three_findings() { # <workspace> [verdict]
  v="${2:-REQUEST_CHANGES}"
  cat > "$1/.code-review/VALIDATED.json" <<JSON
{
  "agent": "review-validator",
  "category": "validation",
  "verdict": "$v",
  "blocking_reason_ids": ["SEM-001"],
  "metrics": {"total": 3, "blocker": 1, "major": 1, "minor": 1, "nit": 0},
  "findings": [
    {"id": "SEM-001", "severity": "BLOCKER", "category": "authz",
     "location": "src/auth.py:42", "title": "Tenant id is not part of the cache key",
     "evidence": "cache[token] = user", "recommendation": "Key the cache by (tenant_id, token).",
     "ux_impact": false, "in_diff": true, "confidence": "HIGH"},
    {"id": "SEM-002", "severity": "MAJOR", "category": "errors",
     "location": "src/legacy.py:7", "title": "Bare except swallows KeyboardInterrupt",
     "evidence": "except:", "recommendation": "Catch Exception.",
     "ux_impact": false, "in_diff": false, "confidence": "MEDIUM"},
    {"id": "ARC-003", "severity": "MINOR", "category": "design",
     "location": "the module as a whole", "title": "Module has two responsibilities",
     "evidence": "n/a", "recommendation": "Split it.",
     "ux_impact": false, "in_diff": true, "confidence": "LOW"}
  ]
}
JSON
}

# A `gh` that records what it was asked to do and answers from fixture files. Never touches a
# network. GH_STUB_COMMENTS / GH_STUB_REVIEWS supply the bodies already "on the PR".
make_gh_stub() { # <bindir>
  mkdir -p "$1"
  cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'CALL %s\n' "$*" >> "${GH_STUB_LOG:-/dev/null}"
case "${1:-}" in
  repo) printf '%s\n' "owner-placeholder/repo-placeholder" ;;
  pr)   printf '%s\n' "7" ;;
  api)
    posting=0; input=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "--method" ] && [ "$a" = "POST" ]; then posting=1; fi
      if [ "$prev" = "--input" ]; then input="$a"; fi
      prev="$a"
    done
    if [ "$posting" -eq 1 ]; then
      if [ -n "$input" ]; then cat "$input" >> "${GH_STUB_PAYLOAD:-/dev/null}"; fi
      printf '%s\n' '{"id": 1, "state": "SUBMITTED"}'
    else
      case "$*" in
        *comments*) cat "${GH_STUB_COMMENTS:-/dev/null}" 2>/dev/null || true ;;
        *reviews*)  cat "${GH_STUB_REVIEWS:-/dev/null}"  2>/dev/null || true ;;
      esac
    fi
    ;;
  *) printf 'gh stub: unsupported invocation: %s\n' "$*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$1/gh"
}

# --- refusals: plant a defect, assert a non-zero exit ----------------------------------------------

# 1. No artifact at all. The review never ran, or ran and died. Either way there is nothing to post,
#    and the one thing that must not happen is a clean review appearing on the PR.
W="$(new_ws refuse-missing)"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "a MISSING VALIDATED.json was accepted (rc=0) - an unfinished review would have been posted"
elif printf '%s' "$out" | grep -q 'does not exist'; then
  pass "a missing VALIDATED.json is refused, with the reason"
else
  fail "a missing VALIDATED.json exited $rc but gave no usable reason: $out"
fi

# 2. Present but truncated. This is the shape a killed validator leaves behind, and it is the case
#    where a naive `[ -f ... ]` check would wave the run through.
W="$(new_ws refuse-malformed)"
printf '%s' '{"agent": "review-validator", "findings": [{"id": "SEM-001",' \
  > "$W/.code-review/VALIDATED.json"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "MALFORMED JSON was accepted (rc=0)"
elif printf '%s' "$out" | grep -q 'not parseable'; then
  pass "an unparseable VALIDATED.json is refused, with the reason"
else
  fail "malformed JSON exited $rc but gave no usable reason: $out"
fi

# 3. No jq. The script must say so and stop, not fall back to a line-oriented parse of JSON it does
#    not control. PATH is emptied rather than reordered so the absence is unambiguous.
W="$(new_ws refuse-no-jq)"
write_three_findings "$W"
mkdir -p "$TMP_ROOT/emptybin"
out="$( cd "$W" && PATH="$TMP_ROOT/emptybin" "$BASH_BIN" "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "a PATH with no jq was accepted (rc=0) - the script parsed JSON with something else"
elif printf '%s' "$out" | grep -q 'jq is required'; then
  pass "a missing jq is refused with a clear message, and nothing is posted"
else
  fail "a missing jq exited $rc but gave no usable reason: $out"
fi

# 4. Zero findings AND no verdict. Not an approval - an empty result. Guessing which was meant is
#    exactly the failure this plugin exists to avoid.
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "empty-document refusal (jq not installed)"
else
  W="$(new_ws refuse-empty)"
  printf '%s' '{"agent": "review-validator", "category": "validation", "findings": []}' \
    > "$W/.code-review/VALIDATED.json"
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "a document with zero findings and NO verdict was accepted (rc=0)"
  elif printf '%s' "$out" | grep -q 'zero findings'; then
    pass "zero findings and no verdict is refused, not treated as an approval"
  else
    fail "an empty document exited $rc but gave no usable reason: $out"
  fi
fi

# 5. A blocking floor that is not one of the four severities. Silently defaulting would change which
#    findings block without anyone being told.
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "invalid blocking floor refusal (jq not installed)"
else
  W="$(new_ws refuse-floor)"
  write_three_findings "$W"
  out="$( cd "$W" && CODE_REVIEW_BLOCKING_FLOOR=WHATEVER bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "an invalid CODE_REVIEW_BLOCKING_FLOOR was accepted (rc=0)"
  elif printf '%s' "$out" | grep -q 'CODE_REVIEW_BLOCKING_FLOOR'; then
    pass "an invalid CODE_REVIEW_BLOCKING_FLOOR is refused, with the reason"
  else
    fail "an invalid floor exited $rc but gave no usable reason: $out"
  fi
fi

# 6. An unknown flag is a typo, and a typo that runs is a review posted with settings nobody chose.
W="$(new_ws refuse-flag)"
write_three_findings "$W"
out="$( cd "$W" && bash "$SCRIPT" --dry-run --post-everything 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then
  fail "an unknown flag was accepted (rc=0)"
else
  pass "an unknown flag is refused"
fi

# --- routing, under --dry-run (no gh call of any kind) ---------------------------------------------

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "routing cases (jq not installed)"
else
  W="$(new_ws route)"
  write_three_findings "$W"
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "a well-formed document was refused (rc=$rc): $out"
  else
    pass "a well-formed document is accepted under --dry-run"

    # in_diff: true with a parseable location -> an inline comment on that path and line.
    if printf '%s' "$out" | grep -q '^  inline  src/auth\.py:42 '; then
      pass "in_diff:true with a parseable location routes INLINE"
    else
      fail "in_diff:true did not route inline: $out"
    fi
    payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
    if printf '%s' "$payload" | jq -e '.comments | length == 1 and (.[0].path == "src/auth.py") and (.[0].line == 42)' >/dev/null 2>&1; then
      pass "the payload carries exactly one inline comment, on src/auth.py line 42"
    else
      fail "the payload's comments array is wrong: $payload"
    fi

    # in_diff: false -> the body. GitHub rejects an inline comment outside the diff, and a rejected
    # comment takes the whole review with it.
    if printf '%s' "$payload" | jq -e '(.body | contains("SEM-002")) and ((.comments // []) | map(.body) | join(" ") | contains("SEM-002") | not)' >/dev/null 2>&1; then
      pass "in_diff:false routes to the review BODY and never inline"
    else
      fail "in_diff:false was not confined to the body: $payload"
    fi

    # An unparseable location degrades to the body rather than being dropped.
    if printf '%s' "$payload" | jq -e '.body | contains("ARC-003")' >/dev/null 2>&1; then
      pass "a finding whose location will not parse degrades to the body, and is not dropped"
    else
      fail "a finding with an unparseable location vanished: $payload"
    fi

    # Every finding in the document reaches the PR somewhere. Silent loss is the failure mode.
    missing=""
    for id in SEM-001 SEM-002 ARC-003; do
      printf '%s' "$payload" | jq -e --arg i "$id" 'tostring | contains($i)' >/dev/null 2>&1 || missing="$missing $id"
    done
    if [ -z "$missing" ]; then
      pass "every finding in the document appears in the payload"
    else
      fail "findings absent from the payload:$missing"
    fi

    # Each posted finding carries its stable marker - the thing a re-run greps for.
    if printf '%s' "$payload" | jq -e 'tostring | contains("code-review-core:finding:SEM-001")' >/dev/null 2>&1; then
      pass "posted findings carry a stable id marker for idempotency"
    else
      fail "no finding marker found in the payload"
    fi
  fi

  # --dry-run must make no gh call at all. Proven by putting a gh on PATH that fails loudly if
  # touched, rather than by reading the source and believing it.
  W="$(new_ws dry-no-gh)"
  write_three_findings "$W"
  mkdir -p "$TMP_ROOT/loudbin"
  printf '#!/usr/bin/env bash\nprintf "gh was called: %%s\\n" "$*" >&2\nexit 66\n' > "$TMP_ROOT/loudbin/gh"
  chmod +x "$TMP_ROOT/loudbin/gh"
  out="$( cd "$W" && PATH="$TMP_ROOT/loudbin:$PATH" bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'gh was called'; then
    pass "--dry-run makes no gh call at all"
  else
    fail "--dry-run touched gh (rc=$rc): $out"
  fi
fi

# --- the verdict mapping ---------------------------------------------------------------------------

check_event() { # <label> <verdict> <expected-event>
  lbl="$1"; verdict="$2"; expected="$3"
  W="$(new_ws "verdict-$verdict")"
  write_three_findings "$W" "$verdict"
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$lbl - the run was refused (rc=$rc): $out"
    return
  fi
  payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
  got="$(printf '%s' "$payload" | jq -r '.event' 2>/dev/null)"
  if [ "$got" = "$expected" ]; then pass "$lbl"; else fail "$lbl - got event '$got', expected '$expected'"; fi
}

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "verdict mapping (jq not installed)"
else
  check_event "REQUEST_CHANGES maps to the REQUEST_CHANGES event" REQUEST_CHANGES REQUEST_CHANGES
  check_event "APPROVE maps to the APPROVE event"                 APPROVE         APPROVE
  # The one that matters: INCOMPLETE means the validator could not finish, which is a different
  # state from "this is fine". Collapsing it into an approval is the worst output available here.
  check_event "INCOMPLETE maps to COMMENT and NEVER to APPROVE"   INCOMPLETE      COMMENT

  W="$(new_ws verdict-incomplete-body)"
  write_three_findings "$W" INCOMPLETE
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"
  payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
  if printf '%s' "$payload" | jq -e '.body | test("incomplete"; "i")' >/dev/null 2>&1; then
    pass "an INCOMPLETE review says so in its body"
  else
    fail "an INCOMPLETE review does not state its incompleteness: $payload"
  fi
fi

# --- command injection: finding text is DATA ---------------------------------------------------------
# A title that would create a file if anything ever re-parsed it, plus a backtick expression in the
# evidence. Both come from a file an agent wrote about a diff; a diff of a shell script contains
# exactly this. The marker path is inside the fixture directory so a regression cannot litter /tmp.

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "command injection case (jq not installed)"
else
  W="$(new_ws injection)"
  PWNED="$TMP_ROOT/pwned-$$-injection-marker"
  rm -f "$PWNED"
  cat > "$W/.code-review/VALIDATED.json" <<JSON
{
  "agent": "review-validator",
  "category": "validation",
  "verdict": "REQUEST_CHANGES",
  "findings": [
    {"id": "INJ-001", "severity": "BLOCKER", "category": "security",
     "location": "src/run.sh:3",
     "title": "\$(touch $PWNED)",
     "evidence": "the script runs \`touch $PWNED\`; rm -rf / #",
     "recommendation": "\$( id > $PWNED ) && echo pwned",
     "ux_impact": false, "in_diff": true, "confidence": "HIGH"}
  ]
}
JSON
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ -e "$PWNED" ]; then
    fail "COMMAND INJECTION: finding text was evaluated and created $PWNED"
    rm -f "$PWNED"
  else
    pass "a finding containing a command substitution and backticks creates no file"
  fi
  if [ "$rc" -ne 0 ]; then
    fail "the injection fixture was refused (rc=$rc) - the case proved nothing: $out"
  else
    pass "the injection fixture is processed normally (rc=0)"
    payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
    if printf '%s' "$payload" | jq -e --arg p "$PWNED" '(.comments // []) | map(.body) | join(" ") | contains("$(touch " + $p + ")")' >/dev/null 2>&1; then
      pass "the hostile title survives into the payload as literal text"
    else
      fail "the hostile title was not carried through literally: $payload"
    fi
  fi
fi

# --- idempotency, against the gh stub ----------------------------------------------------------------

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "idempotency cases (jq not installed)"
else
  make_gh_stub "$TMP_ROOT/ghbin"

  # First run: nothing on the PR yet, so the review is posted and the payload recorded.
  W="$(new_ws post-first)"
  write_three_findings "$W"
  : > "$TMP_ROOT/empty.txt"
  LOG="$TMP_ROOT/first.log"; PAY="$TMP_ROOT/first-payload.json"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$LOG" GH_STUB_PAYLOAD="$PAY" \
          GH_STUB_COMMENTS="$TMP_ROOT/empty.txt" GH_STUB_REVIEWS="$TMP_ROOT/empty.txt" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the first post run failed (rc=$rc): $out"
  elif [ ! -s "$PAY" ]; then
    fail "the first post run exited 0 but sent no payload to gh: $out"
  else
    pass "a first run posts the review through gh"
    if jq -e '.event == "REQUEST_CHANGES"' "$PAY" >/dev/null 2>&1; then
      pass "the posted payload carries the document's verdict as its event"
    else
      fail "the posted payload has the wrong event: $(cat "$PAY")"
    fi
  fi

  # Second run: the PR already carries every marker, so nothing new may be posted.
  W="$(new_ws post-second)"
  write_three_findings "$W"
  cat > "$TMP_ROOT/existing.txt" <<'EXISTING'
Looks good apart from this. <!-- code-review-core:finding:SEM-001 -->
<!-- code-review-core:finding:SEM-002 --> and <!-- code-review-core:finding:ARC-003 -->
EXISTING
  LOG2="$TMP_ROOT/second.log"; PAY2="$TMP_ROOT/second-payload.json"
  : > "$PAY2"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$LOG2" GH_STUB_PAYLOAD="$PAY2" \
          GH_STUB_COMMENTS="$TMP_ROOT/existing.txt" GH_STUB_REVIEWS="$TMP_ROOT/empty.txt" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the re-run failed (rc=$rc): $out"
  elif [ -s "$PAY2" ]; then
    fail "the re-run DUPLICATED the review - a payload was posted again: $(cat "$PAY2")"
  elif printf '%s' "$out" | grep -q 'nothing new to post'; then
    pass "a re-run over already-posted findings posts nothing and says so"
  else
    fail "the re-run posted nothing but gave no explanation: $out"
  fi

  # A partial re-run: two of three findings already present, so exactly one is new.
  W="$(new_ws post-partial)"
  write_three_findings "$W"
  cat > "$TMP_ROOT/partial.txt" <<'PARTIAL'
<!-- code-review-core:finding:SEM-002 -->
<!-- code-review-core:finding:ARC-003 -->
PARTIAL
  PAY3="$TMP_ROOT/third-payload.json"; : > "$PAY3"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$TMP_ROOT/third.log" GH_STUB_PAYLOAD="$PAY3" \
          GH_STUB_COMMENTS="$TMP_ROOT/partial.txt" GH_STUB_REVIEWS="$TMP_ROOT/empty.txt" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the partial re-run failed (rc=$rc): $out"
  elif jq -e '((.comments // []) | length == 1) and ((.comments[0].body | contains("SEM-001")))' "$PAY3" >/dev/null 2>&1; then
    if jq -e '.body | (contains("SEM-002") | not) and (contains("ARC-003") | not)' "$PAY3" >/dev/null 2>&1; then
      pass "a partial re-run posts only the finding that is new"
    else
      fail "a partial re-run re-posted findings already on the PR: $(cat "$PAY3")"
    fi
  else
    fail "a partial re-run did not post the one new finding: $(cat "$PAY3")"
  fi

  # No gh on PATH, and not a dry run: refuse rather than pretend.
  W="$(new_ws refuse-no-gh)"
  write_three_findings "$W"
  out="$( cd "$W" && PATH="$TMP_ROOT/emptybin:$JQ_DIR" "$BASH_BIN" "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "a real post with no gh on PATH was accepted (rc=0)"
  else
    pass "a real post with no gh on PATH is refused"
  fi
fi

# --- portability: the script must also run under zsh --------------------------------------------------

if ! command -v zsh >/dev/null 2>&1; then
  skip "zsh portability case (zsh not installed)"
elif [ "$HAVE_JQ" -eq 0 ]; then
  skip "zsh portability case (jq not installed)"
else
  W="$(new_ws zsh-port)"
  write_three_findings "$W"
  out="$( cd "$W" && zsh "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^  inline  src/auth\.py:42 '; then
    pass "post-review.sh produces the same routing under zsh"
  else
    fail "post-review.sh misbehaves under zsh (rc=$rc): $out"
  fi

  W="$(new_ws zsh-refuse)"
  out="$( cd "$W" && zsh "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "post-review.sh still refuses a missing artifact under zsh"
  else
    fail "post-review.sh accepted a missing artifact under zsh"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  printf 'NOTE: %d case(s) were SKIPPED for a missing binary. A skip is not a pass.\n' "$SKIP"
fi
[ "$FAIL" -eq 0 ]
