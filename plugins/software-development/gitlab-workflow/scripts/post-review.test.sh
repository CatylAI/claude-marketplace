#!/usr/bin/env bash
# post-review.test.sh - the refusal paths of post-review.sh, and the routing it promises.
#
#   bash scripts/post-review.test.sh        # run everything
#   zsh  scripts/post-review.test.sh        # the portability half of the contract
#
# WHY THIS SUITE EXISTS. post-review.sh is mostly a refusal: it is the last thing between an
# unfinished review and a green-looking merge request. A happy-path suite - the payload is built,
# the inline note lands - proves the opposite property and would stay green if every guard were
# deleted. So the cases that matter here PLANT A DEFECT AND ASSERT A NON-ZERO EXIT: no artifact, a
# truncated artifact, no jq, an empty document, a bad floor, an MR with no diff_refs, and the GitLab
# special - a draft note GitLab ACCEPTS and then renders unanchored. A gate nobody has watched fail
# is an assumption, not a check.
#
# The second thing being asserted is that finding text is DATA. Findings are written by agents
# reading a diff, and a diff of a shell script contains command substitutions and backticks as a
# matter of course. One case feeds a title that would create a file if anything ever re-parsed it,
# and asserts the file does not appear.
#
# Nothing is touched outside $TMP_ROOT, which the trap removes on any exit. No network call is made:
# every case either runs --dry-run (which makes no glab call at all) or runs against a `glab` stub
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

# Absolute paths, resolved while PATH is still intact: the no-jq and no-glab cases run the script
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

# The MR object the stub answers a GET with. `diff_refs` is the only part post-review.sh reads, and
# it is the whole reason a GitLab inline note needs a round trip a GitHub one does not.
write_mr_fixture() { # <path> [with-diff-refs: 1|0]
  if [ "${2:-1}" = "1" ]; then
    cat > "$1" <<'MRJSON'
{"iid": 7, "title": "stub merge request",
 "diff_refs": {"base_sha": "base1111111111111111111111111111111111111",
               "start_sha": "start222222222222222222222222222222222222",
               "head_sha": "head3333333333333333333333333333333333333"}}
MRJSON
  else
    printf '%s\n' '{"iid": 7, "title": "stub merge request", "diff_refs": null}' > "$1"
  fi
}

# A `glab` that records what it was asked to do and answers from fixture files. Never touches a
# network. It emits HTTP headers only when `-i` was passed, exactly as glab does, because the
# header/body split is a thing post-review.sh depends on.
make_glab_stub() { # <bindir>
  mkdir -p "$1"
  cat > "$1/glab" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'CALL %s\n' "$*" >> "${GLAB_STUB_LOG:-/dev/null}"

emit() { # <status-line> <json-body>
  if [ "${INC:-0}" -eq 1 ]; then
    printf 'HTTP/1.1 %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n'
    printf '\r\n'
  fi
  printf '%s\n' "$2"
}

case "${1:-}" in
  mr)
    # `glab mr view --output json`
    cat "${GLAB_STUB_MR:-/dev/null}" 2>/dev/null || true
    exit 0 ;;
  api) : ;;
  *) printf 'glab stub: unsupported invocation: %s\n' "$*" >&2; exit 1 ;;
esac

shift
METHOD="GET"; INPUT=""; ENDPOINT=""; INC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X)  METHOD="${2:-}"; shift 2 ;;
    --input)      INPUT="${2:-}"; shift 2 ;;
    --header|-H)  shift 2 ;;
    --output)     shift 2 ;;
    -i|--include) INC=1; shift ;;
    --paginate|--silent) shift ;;
    *) [ -z "$ENDPOINT" ] && ENDPOINT="$1"; shift ;;
  esac
done

if [ "$METHOD" = "GET" ]; then
  case "$ENDPOINT" in
    */draft_notes) cat "${GLAB_STUB_DRAFTS:-/dev/null}" 2>/dev/null || true ;;
    */notes)       cat "${GLAB_STUB_NOTES:-/dev/null}"  2>/dev/null || true ;;
    */merge_requests/*) cat "${GLAB_STUB_MR:-/dev/null}" 2>/dev/null || true ;;
    *) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

if [ "$METHOD" = "DELETE" ]; then
  printf '%s\n' "$ENDPOINT" >> "${GLAB_STUB_DELETED:-/dev/null}"
  emit "204 No Content" '{}'
  exit 0
fi

# POST from here down.
case "$ENDPOINT" in
  */draft_notes/bulk_publish)
    printf 'bulk\n' >> "${GLAB_STUB_BULK:-/dev/null}"
    emit "${GLAB_STUB_BULK_STATUS:-200 OK}" '{}'
    ;;
  */draft_notes)
    [ -n "$INPUT" ] && cat "$INPUT" >> "${GLAB_STUB_DRAFT_PAYLOADS:-/dev/null}"
    N=1
    if [ -n "${GLAB_STUB_DRAFT_PAYLOADS:-}" ] && [ -f "${GLAB_STUB_DRAFT_PAYLOADS}" ]; then
      N="$(grep -c '"position"' "${GLAB_STUB_DRAFT_PAYLOADS}" 2>/dev/null || echo 1)"
    fi
    if [ "${GLAB_STUB_POSITION_NULL:-0}" = "1" ]; then
      emit "201 Created" "{\"id\": $((100 + N)), \"position\": null}"
    else
      emit "201 Created" "{\"id\": $((100 + N)), \"position\": {\"position_type\": \"text\"}}"
    fi
    ;;
  */notes)
    [ -n "$INPUT" ] && cat "$INPUT" >> "${GLAB_STUB_SUMMARY:-/dev/null}"
    emit "201 Created" '{"id": 900}'
    ;;
  */approve)
    printf 'approve\n' >> "${GLAB_STUB_APPROVE:-/dev/null}"
    emit "201 Created" '{"id": 1, "state": "approved"}'
    ;;
  *)
    emit "404 Not Found" '{"message": "404 Not Found"}'
    ;;
esac
STUB
  chmod +x "$1/glab"
}

# Fresh, empty per-case recording files, so one case cannot read another's evidence.
stub_env_reset() { # <tag> -> exports GLAB_STUB_* for this case
  S="$TMP_ROOT/stub-$1"
  mkdir -p "$S"
  : > "$S/log"; : > "$S/drafts.json"; : > "$S/summary.json"
  : > "$S/bulk"; : > "$S/approve"; : > "$S/deleted"
  write_mr_fixture "$S/mr.json" "${2:-1}"
  : > "$S/notes.json"
  : > "$S/draftlist.json"
}

# --- refusals: plant a defect, assert a non-zero exit ----------------------------------------------

# 1. No artifact at all. The review never ran, or ran and died. Either way there is nothing to post,
#    and the one thing that must not happen is a clean review appearing on the MR.
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

# --- routing, under --dry-run (no glab call of any kind) -------------------------------------------

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

    # in_diff: true with a parseable location -> an inline note on that path and line.
    if printf '%s' "$out" | grep -q '^  inline  src/auth\.py:42 '; then
      pass "in_diff:true with a parseable location routes INLINE"
    else
      fail "in_diff:true did not route inline: $out"
    fi
    payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
    if printf '%s' "$payload" | jq -e '.inline | length == 1
        and (.[0].draft.position.new_path == "src/auth.py")
        and (.[0].draft.position.new_line == 42)' >/dev/null 2>&1; then
      pass "the payload carries exactly one inline draft note, on src/auth.py line 42"
    else
      fail "the payload's inline array is wrong: $payload"
    fi

    # The position object is the whole GitLab-specific risk. Assert every field it must carry.
    if printf '%s' "$payload" | jq -e '.inline[0].draft.position
        | has("base_sha") and has("start_sha") and has("head_sha")
          and has("new_path") and has("old_path") and has("new_line")
          and (.position_type == "text")' >/dev/null 2>&1; then
      pass "the position object carries base_sha, start_sha, head_sha, new_path, old_path, new_line"
    else
      fail "the position object is missing a required field: $payload"
    fi

    # A draft note's text field is `note`, not `body`. GitLab's two note endpoints disagree, and
    # getting this backwards is a 400 on every inline comment.
    if printf '%s' "$payload" | jq -e '(.inline[0].draft | has("note")) and (.summary | has("body"))' >/dev/null 2>&1; then
      pass 'the draft note uses `note` and the summary uses `body`, as the two endpoints require'
    else
      fail "the payload field names do not match GitLab's endpoints: $payload"
    fi

    # in_diff: false -> the body. A GitLab diff note cannot anchor outside the MR's diff.
    if printf '%s' "$payload" | jq -e '(.summary.body | contains("SEM-002"))
        and ((.inline // []) | map(.draft.note) | join(" ") | contains("SEM-002") | not)' >/dev/null 2>&1; then
      pass "in_diff:false routes to the MR-level note BODY and never inline"
    else
      fail "in_diff:false was not confined to the body: $payload"
    fi

    # An unparseable location degrades to the body rather than being dropped.
    if printf '%s' "$payload" | jq -e '.summary.body | contains("ARC-003")' >/dev/null 2>&1; then
      pass "a finding whose location will not parse degrades to the body, and is not dropped"
    else
      fail "a finding with an unparseable location vanished: $payload"
    fi

    # Every finding in the document reaches the MR somewhere. Silent loss is the failure mode.
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

  # --dry-run must make no glab call at all. Proven by putting a glab on PATH that fails loudly if
  # touched, rather than by reading the source and believing it.
  W="$(new_ws dry-no-glab)"
  write_three_findings "$W"
  mkdir -p "$TMP_ROOT/loudbin"
  printf '#!/usr/bin/env bash\nprintf "glab was called: %%s\\n" "$*" >&2\nexit 66\n' > "$TMP_ROOT/loudbin/glab"
  chmod +x "$TMP_ROOT/loudbin/glab"
  out="$( cd "$W" && PATH="$TMP_ROOT/loudbin:$PATH" bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'glab was called'; then
    pass "--dry-run makes no glab call at all"
  else
    fail "--dry-run touched glab (rc=$rc): $out"
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
  got="$(printf '%s\n' "$out" | sed -n 's/^  review event:   //p')"
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
  if printf '%s' "$payload" | jq -e '.summary.body | test("incomplete"; "i")' >/dev/null 2>&1; then
    pass "an INCOMPLETE review says so in its body"
  else
    fail "an INCOMPLETE review does not state its incompleteness: $payload"
  fi
  # On GitLab the approval is a separate call, so "never an approval" has to be asserted about the
  # call as well as about the event.
  if printf '%s\n' "$out" | grep -q '^  approve call:   no$'; then
    pass "an INCOMPLETE review plans no approve call"
  else
    fail "an INCOMPLETE review planned an approve call: $out"
  fi

  W="$(new_ws verdict-approve-suppressed)"
  write_three_findings "$W" APPROVE
  out="$( cd "$W" && bash "$SCRIPT" --dry-run --no-approve 2>&1 )"
  if printf '%s\n' "$out" | grep -q '^  approve call:   no$'; then
    pass "--no-approve suppresses the approve call even on an APPROVE verdict"
  else
    fail "--no-approve did not suppress the approve call: $out"
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
    if printf '%s' "$payload" | jq -e --arg p "$PWNED" '(.inline // []) | map(.draft.note) | join(" ") | contains("$(touch " + $p + ")")' >/dev/null 2>&1; then
      pass "the hostile title survives into the payload as literal text"
    else
      fail "the hostile title was not carried through literally: $payload"
    fi
    if printf '%s' "$payload" | jq -e --arg p "$PWNED" '(.inline // []) | map(.draft.note) | join(" ") | contains("`touch " + $p + "`")' >/dev/null 2>&1; then
      pass "the backtick expression in the evidence survives as literal text"
    else
      fail "the backtick evidence was not carried through literally: $payload"
    fi
  fi

  # The same fixture against the stub: a real post must not evaluate it either.
  make_glab_stub "$TMP_ROOT/glabbin"
  stub_env_reset injection
  S="$TMP_ROOT/stub-injection"
  rm -f "$PWNED"
  out="$( cd "$W" && PATH="$TMP_ROOT/glabbin:$PATH" \
          GLAB_STUB_LOG="$S/log" GLAB_STUB_MR="$S/mr.json" \
          GLAB_STUB_NOTES="$S/notes.json" GLAB_STUB_DRAFTS="$S/draftlist.json" \
          GLAB_STUB_DRAFT_PAYLOADS="$S/drafts.json" GLAB_STUB_SUMMARY="$S/summary.json" \
          GLAB_STUB_BULK="$S/bulk" GLAB_STUB_APPROVE="$S/approve" GLAB_STUB_DELETED="$S/deleted" \
          bash "$SCRIPT" --mr 7 2>&1 )"; rc=$?
  if [ -e "$PWNED" ]; then
    fail "COMMAND INJECTION on the posting path: $PWNED was created"
    rm -f "$PWNED"
  else
    pass "the posting path evaluates no finding text either"
  fi
fi

# --- posting, against the glab stub ------------------------------------------------------------------

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "posting and idempotency cases (jq not installed)"
else
  make_glab_stub "$TMP_ROOT/glabbin"

  run_post() { # <workspace> <stub-tag> [extra args...]
    _w="$1"; _t="$2"; shift 2
    _s="$TMP_ROOT/stub-$_t"
    ( cd "$_w" && PATH="$TMP_ROOT/glabbin:$PATH" \
        GLAB_STUB_LOG="$_s/log" GLAB_STUB_MR="$_s/mr.json" \
        GLAB_STUB_NOTES="$_s/notes.json" GLAB_STUB_DRAFTS="$_s/draftlist.json" \
        GLAB_STUB_DRAFT_PAYLOADS="$_s/drafts.json" GLAB_STUB_SUMMARY="$_s/summary.json" \
        GLAB_STUB_BULK="$_s/bulk" GLAB_STUB_APPROVE="$_s/approve" GLAB_STUB_DELETED="$_s/deleted" \
        GLAB_STUB_POSITION_NULL="${STUB_POSITION_NULL:-0}" \
        bash "$SCRIPT" "$@" 2>&1 )
  }

  # First run: nothing on the MR yet, so the review is posted and every payload recorded.
  W="$(new_ws post-first)"
  write_three_findings "$W"
  stub_env_reset first
  S="$TMP_ROOT/stub-first"
  out="$(run_post "$W" first --mr 7)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the first post run failed (rc=$rc): $out"
  elif [ ! -s "$S/drafts.json" ] || [ ! -s "$S/summary.json" ]; then
    fail "the first post run exited 0 but sent no payload to glab: $out"
  else
    pass "a first run posts the inline draft notes and the summary through glab"
    if jq -e '.position.base_sha == "base1111111111111111111111111111111111111"
              and .position.start_sha == "start222222222222222222222222222222222222"
              and .position.head_sha == "head3333333333333333333333333333333333333"' \
         "$S/drafts.json" >/dev/null 2>&1; then
      pass "the position SHAs come from the merge request's diff_refs, not from the checkout"
    else
      fail "the position SHAs are not the MR's diff_refs: $(cat "$S/drafts.json")"
    fi
    if [ -s "$S/bulk" ]; then
      pass "the verified drafts are published with one bulk_publish call"
    else
      fail "the drafts were never published"
    fi
    if [ ! -s "$S/approve" ]; then
      pass "a REQUEST_CHANGES review makes no approve call"
    else
      fail "a REQUEST_CHANGES review called approve"
    fi
  fi

  # An APPROVE verdict is the only one with an action behind it.
  W="$(new_ws post-approve)"
  write_three_findings "$W" APPROVE
  stub_env_reset approve
  S="$TMP_ROOT/stub-approve"
  out="$(run_post "$W" approve --mr 7)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$S/approve" ]; then
    pass "an APPROVE verdict calls the approve endpoint"
  else
    fail "an APPROVE verdict did not approve (rc=$rc): $out"
  fi

  W="$(new_ws post-incomplete)"
  write_three_findings "$W" INCOMPLETE
  stub_env_reset incomplete
  S="$TMP_ROOT/stub-incomplete"
  out="$(run_post "$W" incomplete --mr 7)"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$S/approve" ]; then
    pass "an INCOMPLETE verdict posts the review and never approves"
  else
    fail "an INCOMPLETE verdict approved or failed (rc=$rc): $out"
  fi

  # Second run: the MR already carries every marker, so nothing new may be posted.
  W="$(new_ws post-second)"
  write_three_findings "$W"
  stub_env_reset second
  S="$TMP_ROOT/stub-second"
  cat > "$S/notes.json" <<'EXISTING'
[{"body": "Looks good apart from this. <!-- code-review-core:finding:SEM-001 -->"},
 {"body": "<!-- code-review-core:finding:SEM-002 --> and <!-- code-review-core:finding:ARC-003 -->"}]
EXISTING
  out="$(run_post "$W" second --mr 7)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the re-run failed (rc=$rc): $out"
  elif [ -s "$S/drafts.json" ] || [ -s "$S/summary.json" ]; then
    fail "the re-run DUPLICATED the review - a payload was posted again"
  elif printf '%s' "$out" | grep -q 'nothing new to post'; then
    pass "a re-run over already-posted findings posts nothing and says so"
  else
    fail "the re-run posted nothing but gave no explanation: $out"
  fi

  # A partial re-run: two of three findings already present, so exactly one is new.
  W="$(new_ws post-partial)"
  write_three_findings "$W"
  stub_env_reset partial
  S="$TMP_ROOT/stub-partial"
  cat > "$S/notes.json" <<'PARTIAL'
[{"body": "<!-- code-review-core:finding:SEM-002 -->"},
 {"body": "<!-- code-review-core:finding:ARC-003 -->"}]
PARTIAL
  out="$(run_post "$W" partial --mr 7)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "the partial re-run failed (rc=$rc): $out"
  elif jq -e '.note | contains("SEM-001")' "$S/drafts.json" >/dev/null 2>&1 \
       && jq -e '.body | (contains("SEM-002") | not) and (contains("ARC-003") | not)' \
            "$S/summary.json" >/dev/null 2>&1; then
    pass "a partial re-run posts only the finding that is new"
  else
    fail "a partial re-run posted the wrong set: drafts=$(cat "$S/drafts.json") summary=$(cat "$S/summary.json")"
  fi

  # A draft note the API ACCEPTS with `position: null`. 201, exit 0, and the note renders as an
  # ordinary comment nobody asked for. This is the GitLab-specific failure the whole draft-then-
  # publish shape exists to catch, so it is asserted rather than assumed.
  W="$(new_ws post-unanchored)"
  write_three_findings "$W"
  stub_env_reset unanchored
  S="$TMP_ROOT/stub-unanchored"
  STUB_POSITION_NULL=1
  out="$(run_post "$W" unanchored --mr 7)"; rc=$?
  STUB_POSITION_NULL=0
  if [ "$rc" -eq 0 ]; then
    fail "a draft note that came back UNANCHORED (position: null) was accepted (rc=0)"
  elif [ -s "$S/bulk" ]; then
    fail "an unanchored draft note was published anyway"
  elif [ -s "$S/deleted" ] && printf '%s' "$out" | grep -q 'position'; then
    pass "a draft note that comes back with position: null fails the run, and its draft is deleted"
  else
    fail "an unanchored note exited $rc but left no usable evidence: $out (deleted=$(cat "$S/deleted"))"
  fi

  # An MR with no diff_refs cannot anchor anything. Posting every finding unanchored would be a
  # silent downgrade, so it is a refusal.
  W="$(new_ws post-no-diffrefs)"
  write_three_findings "$W"
  stub_env_reset nodiffrefs 0
  S="$TMP_ROOT/stub-nodiffrefs"
  out="$(run_post "$W" nodiffrefs --mr 7)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "an MR with no diff_refs was accepted (rc=0)"
  elif printf '%s' "$out" | grep -q 'diff_refs'; then
    pass "an MR with no usable diff_refs is refused, with the reason"
  else
    fail "a missing diff_refs exited $rc but gave no usable reason: $out"
  fi

  # No --mr: the IID is resolved from the current branch's MR through `glab mr view`.
  W="$(new_ws post-resolve-iid)"
  write_three_findings "$W"
  stub_env_reset resolve
  S="$TMP_ROOT/stub-resolve"
  out="$(run_post "$W" resolve)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'merge request !7'; then
    pass "the merge request IID is resolved from the current branch when --mr is omitted"
  else
    fail "the IID was not resolved (rc=$rc): $out"
  fi

  # No glab on PATH, and not a dry run: refuse rather than pretend.
  W="$(new_ws refuse-no-glab)"
  write_three_findings "$W"
  out="$( cd "$W" && PATH="$TMP_ROOT/emptybin:$JQ_DIR" "$BASH_BIN" "$SCRIPT" --mr 7 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "a real post with no glab on PATH was accepted (rc=0)"
  else
    pass "a real post with no glab on PATH is refused"
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

  W="$(new_ws zsh-post)"
  write_three_findings "$W"
  stub_env_reset zshpost
  S="$TMP_ROOT/stub-zshpost"
  out="$( cd "$W" && PATH="$TMP_ROOT/glabbin:$PATH" \
          GLAB_STUB_LOG="$S/log" GLAB_STUB_MR="$S/mr.json" \
          GLAB_STUB_NOTES="$S/notes.json" GLAB_STUB_DRAFTS="$S/draftlist.json" \
          GLAB_STUB_DRAFT_PAYLOADS="$S/drafts.json" GLAB_STUB_SUMMARY="$S/summary.json" \
          GLAB_STUB_BULK="$S/bulk" GLAB_STUB_APPROVE="$S/approve" GLAB_STUB_DELETED="$S/deleted" \
          zsh "$SCRIPT" --mr 7 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$S/drafts.json" ] && [ -s "$S/bulk" ]; then
    pass "post-review.sh posts the same way under zsh"
  else
    fail "post-review.sh misbehaves on the posting path under zsh (rc=$rc): $out"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  printf 'NOTE: %d case(s) were SKIPPED for a missing binary. A skip is not a pass.\n' "$SKIP"
fi
[ "$FAIL" -eq 0 ]
