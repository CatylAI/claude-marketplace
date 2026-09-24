#!/usr/bin/env bash
# post-review.test.sh - the refusal paths of post-review.sh, and the routing it promises.
#
#   bash scripts/post-review.test.sh        # run everything
#   zsh  scripts/post-review.test.sh        # the portability half of the contract
#
# post-review.sh is mostly a refusal: it is the last thing between an unfinished review and an
# approved-looking merge request. So the cases that matter here plant a defect and assert a non-zero
# exit, and finding text is asserted to stay data. The R and M cases are regressions: each one fails
# on the version of the script before the transport review.
#
# Nothing is touched outside $TMP_ROOT, which the trap removes on any exit. No network call is made:
# every case either runs --dry-run (no glab call at all) or runs against a stateful `glab` stub that
# keeps one simulated merge request per case in a directory, so a second run sees what the first
# one posted, the way GitLab would.
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
# with a deliberately stripped PATH.
BASH_BIN="$(command -v bash)"
JQ_DIR=""
[ "$HAVE_JQ" -eq 1 ] && JQ_DIR="$(dirname "$(command -v jq)")"

# 40-hex SHAs: the latest diff version (d...), an older one (a...), and a commit GitLab never saw.
SHA_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_START=cccccccccccccccccccccccccccccccccccccccc
SHA_HEAD=dddddddddddddddddddddddddddddddddddddddd
SHA_OLD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_GONE=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# --- fixtures -------------------------------------------------------------------------------------

new_ws() { # <name> -> prints the workspace path
  d="$TMP_ROOT/$1"
  mkdir -p "$d/.code-review"
  printf '%s' "$d"
}

# One in-diff finding with a parseable location, one pre-existing finding, one whose location is
# prose. Covers all three routing outcomes.
write_three_findings() { # <workspace> [verdict]
  v="${2:-REQUEST_CHANGES}"
  cat > "$1/.code-review/VALIDATED.json" <<JSON
{
  "agent": "review-validator",
  "category": "validation",
  "verdict": "$v",
  "blocking_floor": "MINOR",
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

fnd() { # <id> <severity> <category> <location> <title> [in_diff] [evidence] -> one finding as JSON
  jq -nc --arg id "$1" --arg s "$2" --arg c "$3" --arg l "$4" --arg t "$5" \
    --argjson d "${6:-true}" --arg e "${7:-e}" \
    '{id: $id, severity: $s, category: $c, location: $l, title: $t, evidence: $e,
      recommendation: "r", in_diff: $d, ux_impact: false, confidence: "HIGH"}'
}
vdoc() { # <workspace> <verdict> [finding-json...] -> writes VALIDATED.json
  _w="$1"; _v="$2"; shift 2
  printf '%s\n' "$@" | jq -s --arg v "$_v" \
    '{agent: "review-validator", category: "VALIDATED", verdict: $v, blocking_floor: "MINOR",
      blocking_reason_ids: [], findings: .}' > "$_w/.code-review/VALIDATED.json"
}
reviewed() { # <workspace> <sha> -> writes CONTEXT.json
  printf '{"reviewed_sha": "%s"}\n' "$2" > "$1/.code-review/CONTEXT.json"
}

dry_payload() { # <workspace> [extra args...] -> prints the dry-run payload JSON
  _w="$1"; shift
  ( cd "$_w" && bash "$SCRIPT" --dry-run "$@" 2>/dev/null ) | sed -n '/^payload:/,$p' | sed '1d'
}

# --- the glab stub ----------------------------------------------------------------------------------
# A stateful fake GitLab for one merge request, kept in $GLAB_STUB_DIR:
#   mr.json versions.json version.json   the MR and its diff (see new_mr); version-<id>.json when a
#                                         diff version differs from the latest
#   notes.json drafts.json approvals.json the state a real MR has; writes update it
#   publish.log approve.log unapprove.log each accepted payload, one per line
# Knobs (all optional):
#   GLAB_STUB_ME                  username `glab api user` returns (default: review-bot)
#   GLAB_STUB_FAIL_READ=<suffix>  notes | draft_notes | approvals | versions: that read exits 1
#   GLAB_STUB_NULL_PATH=<path>    a draft on that path comes back 201 with position: null
#   GLAB_STUB_REJECT_PATH=<path>  a draft on that path gets 400, as a bad line_code does
#   GLAB_STUB_CONTEXT=<p>:<new>:<old>  that line is an unchanged line: without old_line=<old> the
#                                 position does not resolve (201, position: null), as on GitLab
#   GLAB_STUB_IGNORE_NOTE=1       bulk_publish ignores `note` and `reviewer_state` (older GitLab)
#   GLAB_STUB_BP422=1             bulk_publish publishes the drafts, then answers 422 on the summary
#                                 note, so `reviewer_state` is never applied (GitLab sets it after
#                                 the note); POST notes still works
#   GLAB_STUB_BP400=1             bulk_publish answers 400 to any call carrying `note`, publishing nothing
# The reviewer state GitLab applied is written to reviewer_state; approvals.json flips
# user_can_approve with user_has_approved, as GitLab's eligible_for_approval_by? does.
#   GLAB_STUB_SUMMARY_FAIL=1      the summary cannot be created: bulk_publish publishes the drafts and
#                                 then answers 422; POST notes answers 500
#   GLAB_STUB_FAIL_UNAPPROVE=1    /unapprove answers 401
make_glab_stub() { # <bindir>
  mkdir -p "$1"
  cat > "$1/glab" <<'STUB'
#!/usr/bin/env bash
set -u
D="${GLAB_STUB_DIR:?}"
ME="${GLAB_STUB_ME:-review-bot}"
printf 'CALL %s\n' "$*" >> "$D/log"

emit() { # <status-line> <json-body>
  if [ "$INC" -eq 1 ]; then printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\n\r\n' "$1"; fi
  printf '%s\n' "$2"
}
nextid() { n="$(cat "$D/nextid" 2>/dev/null || echo 1000)"; echo $((n + 1)) > "$D/nextid"; echo "$n"; }
upd() { jq "$@" > "$D/t.json" && mv "$D/t.json" "$D/$_file"; }

case "${1:-}" in
  mr)  cat "$D/mr.json"; exit 0 ;;
  api) shift ;;
  *)   printf 'glab stub: unsupported invocation: %s\n' "$*" >&2; exit 1 ;;
esac

METHOD="GET"; INPUT=""; EP=""; INC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X)  METHOD="$2"; shift 2 ;;
    --input)      INPUT="$2"; shift 2 ;;
    --header|-H|--output) shift 2 ;;
    -i|--include) INC=1; shift ;;
    --paginate|--silent) shift ;;
    *) [ -z "$EP" ] && EP="$1"; shift ;;
  esac
done

if [ "$METHOD" = "GET" ]; then
  case "$EP" in
    user) printf '{"username": "%s"}\n' "$ME"; exit 0 ;;
  esac
  suffix="${EP##*/}"
  case "$EP" in */versions/*) suffix="version" ;; esac
  if [ -n "${GLAB_STUB_FAIL_READ:-}" ] && [ "$suffix" = "$GLAB_STUB_FAIL_READ" ]; then
    printf 'glab: 502 Bad Gateway\n' >&2; exit 1
  fi
  case "$EP" in
    */versions/*)   v="${EP##*/}"; if [ -f "$D/version-$v.json" ]; then cat "$D/version-$v.json"; else cat "$D/version.json"; fi ;;
    */versions)     cat "$D/versions.json" ;;
    */notes)        cat "$D/notes.json" ;;
    */draft_notes)  cat "$D/drafts.json" ;;
    */approvals)    cat "$D/approvals.json" ;;
    */merge_requests/*) cat "$D/mr.json" ;;
    *) printf 'glab stub: unsupported GET %s\n' "$EP" >&2; exit 1 ;;
  esac
  exit 0
fi

if [ "$METHOD" = "DELETE" ]; then
  id="${EP##*/}"
  _file=drafts.json; upd --argjson i "$id" 'map(select(.id != $i))' "$D/drafts.json"
  printf '%s\n' "$id" >> "$D/deleted.log"
  emit "204 No Content" ''
  exit 0
fi

case "$EP" in
  */draft_notes/bulk_publish)
    if [ "${GLAB_STUB_BP400:-0}" = "1" ] && jq -e 'has("note")' "$INPUT" >/dev/null; then
      emit "400 Bad Request" '{"error": "note is invalid"}'; exit 0
    fi
    jq -c . "$INPUT" >> "$D/publish.log"
    _file=notes.json; upd --slurpfile d "$D/drafts.json" --arg me "$ME" \
      '. + [$d[0][] | {id: .id, body: .note, author: {username: $me}, system: false, position: .position}]' "$D/notes.json"
    printf '[]\n' > "$D/drafts.json"
    if { [ "${GLAB_STUB_SUMMARY_FAIL:-0}" = "1" ] || [ "${GLAB_STUB_BP422:-0}" = "1" ]; } && jq -e 'has("note")' "$INPUT" >/dev/null; then
      emit "422 Unprocessable Entity" '{"message": "Note could not be created"}'; exit 0
    fi
    if [ "${GLAB_STUB_IGNORE_NOTE:-0}" != "1" ] && jq -e 'has("note")' "$INPUT" >/dev/null; then
      nid="$(nextid)"
      _file=notes.json; upd --slurpfile p "$INPUT" --arg me "$ME" --argjson i "$nid" \
        '. + [{id: $i, body: $p[0].note, author: {username: $me}, system: false}]' "$D/notes.json"
    fi
    if [ "${GLAB_STUB_IGNORE_NOTE:-0}" != "1" ] && jq -e 'has("reviewer_state")' "$INPUT" >/dev/null; then
      jq -r .reviewer_state "$INPUT" > "$D/reviewer_state"
    fi
    emit "204 No Content" ''
    ;;
  */draft_notes)
    jq -c . "$INPUT" >> "$D/draftposts.log"
    path="$(jq -r '.position.new_path' "$INPUT")"
    line="$(jq -r '.position.new_line' "$INPUT")"
    oldl="$(jq -r '.position.old_line // ""' "$INPUT")"
    if [ -n "${GLAB_STUB_REJECT_PATH:-}" ] && [ "$path" = "$GLAB_STUB_REJECT_PATH" ]; then
      emit "400 Bad Request" '{"message": {"line_code": ["can'"'"'t be blank"]}}'; exit 0
    fi
    pos="$(jq -c .position "$INPUT")"
    if [ -n "${GLAB_STUB_NULL_PATH:-}" ] && [ "$path" = "$GLAB_STUB_NULL_PATH" ]; then pos=null; fi
    if [ -n "${GLAB_STUB_CONTEXT:-}" ]; then
      cp="${GLAB_STUB_CONTEXT%%:*}"; rest="${GLAB_STUB_CONTEXT#*:}"
      if [ "$path" = "$cp" ] && [ "$line" = "${rest%%:*}" ] && [ "$oldl" != "${rest#*:}" ]; then pos=null; fi
    fi
    nid="$(nextid)"
    _file=drafts.json; upd --slurpfile p "$INPUT" --argjson i "$nid" --argjson pos "$pos" \
      '. + [{id: $i, note: $p[0].note, position: $pos}]' "$D/drafts.json"
    emit "201 Created" "$(jq -nc --argjson i "$nid" --argjson pos "$pos" '{id: $i, position: $pos}')"
    ;;
  */notes)
    if [ "${GLAB_STUB_SUMMARY_FAIL:-0}" = "1" ]; then emit "500 Internal Server Error" '{"message": "500"}'; exit 0; fi
    nid="$(nextid)"
    _file=notes.json; upd --slurpfile p "$INPUT" --arg me "$ME" --argjson i "$nid" \
      '. + [{id: $i, body: $p[0].body, author: {username: $me}, system: false}]' "$D/notes.json"
    emit "201 Created" "{\"id\": $nid}"
    ;;
  */unapprove)
    if [ "${GLAB_STUB_FAIL_UNAPPROVE:-0}" = "1" ]; then emit "401 Unauthorized" '{"message": "401 Unauthorized"}'; exit 0; fi
    printf 'unapprove\n' >> "$D/unapprove.log"
    _file=approvals.json; upd '.user_has_approved = false | .user_can_approve = true' "$D/approvals.json"
    emit "201 Created" '{}'
    ;;
  */approve)
    jq -c . "$INPUT" >> "$D/approve.log"
    _file=approvals.json; upd '.user_has_approved = true | .user_can_approve = false' "$D/approvals.json"
    emit "201 Created" '{"approved": true}'
    ;;
  *) emit "404 Not Found" '{"message": "404 Not Found"}' ;;
esac
STUB
  chmod +x "$1/glab"
}

# The MR diff: src/auth.py has context 40-41, an added 42 and context 43 (old 42); src/run.sh and
# src/app.py and tests/fx.sh and src/api/handler.py have added lines.
new_mr() { # <name> -> prints the state dir
  _d="$TMP_ROOT/mr-$1"; mkdir -p "$_d"
  jq -n --arg b "$SHA_BASE" --arg s "$SHA_START" --arg h "$SHA_HEAD" \
    '{iid: 7, title: "stub", author: {username: "mr-author"},
      diff_refs: {base_sha: $b, start_sha: $s, head_sha: $h}}' > "$_d/mr.json"
  jq -n --arg b "$SHA_BASE" --arg s "$SHA_START" --arg h "$SHA_HEAD" --arg o "$SHA_OLD" \
    '[{id: 5, head_commit_sha: $h, base_commit_sha: $b, start_commit_sha: $s},
      {id: 4, head_commit_sha: $o, base_commit_sha: $b, start_commit_sha: $s}]' > "$_d/versions.json"
  jq -n --arg b "$SHA_BASE" --arg s "$SHA_START" --arg h "$SHA_HEAD" \
    '{id: 5, head_commit_sha: $h, base_commit_sha: $b, start_commit_sha: $s, diffs: [
       {old_path: "src/auth.py", new_path: "src/auth.py",
        diff: "@@ -40,3 +40,4 @@ def get\n ctx40\n ctx41\n+added42\n ctx43\n"},
       {old_path: "src/run.sh", new_path: "src/run.sh", diff: "@@ -1,2 +1,3 @@\n a\n b\n+c\n"},
       {old_path: "src/old_app.py", new_path: "src/app.py",
        diff: "@@ -0,0 +1,10 @@\n+1\n+2\n+3\n+4\n+5\n+6\n+7\n+8\n+9\n+10\n"},
       {old_path: "tests/fx.sh", new_path: "tests/fx.sh", diff: "@@ -8,1 +8,2 @@\n x\n+y\n"},
       {old_path: "src/api/handler.py", new_path: "src/api/handler.py",
        diff: "@@ -39,1 +39,3 @@\n x\n+y\n+z\n"}]}' > "$_d/version.json"
  jq --arg o "$SHA_OLD" '.id = 4 | .head_commit_sha = $o' "$_d/version.json" > "$_d/version-4.json"
  printf '[]\n' > "$_d/notes.json"; printf '[]\n' > "$_d/drafts.json"
  printf '{"user_has_approved": false, "user_can_approve": true}\n' > "$_d/approvals.json"
  : > "$_d/log"; : > "$_d/publish.log"; : > "$_d/approve.log"; : > "$_d/unapprove.log"
  : > "$_d/deleted.log"; : > "$_d/draftposts.log"
  printf '%s' "$_d"
}

# A real post against the stub. Sets OUT and RC. Knobs go in as VAR=value before `--`.
mr_round() { # <workspace> <state-dir> [VAR=value...] [-- script-args...]
  _w="$1"; _d="$2"; shift 2
  : > "$_d/publish.log"; : > "$_d/approve.log"; : > "$_d/draftposts.log"
  OUT="$( cd "$_w" || exit 99
          export PATH="$TMP_ROOT/glabbin:$PATH" GLAB_STUB_DIR="$_d"
          while [ $# -gt 0 ] && [ "$1" != "--" ]; do export "$1"; shift; done
          [ $# -gt 0 ] && shift
          bash "$SCRIPT" --mr 7 "$@" 2>&1 )"; RC=$?
}
published_summary() { # <state-dir> -> the summary text that was published this round
  jq -r '.note // empty' "$1/publish.log" | head -c 2000000
}
summary_notes() { # <state-dir> -> how many summaries are on the MR
  jq '[.[] | select(.body | startswith("## Code review"))] | length' "$1/notes.json"
}

# --- refusals: plant a defect, assert a non-zero exit ----------------------------------------------

W="$(new_ws refuse-missing)"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'does not exist'; then
  pass "a missing VALIDATED.json is refused, with the reason"
else
  fail "a missing VALIDATED.json was not refused properly (rc=$rc): $out"
fi

W="$(new_ws refuse-malformed)"
printf '%s' '{"agent": "review-validator", "findings": [{"id": "SEM-001",' > "$W/.code-review/VALIDATED.json"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not parseable'; then
  pass "an unparseable VALIDATED.json is refused, with the reason"
else
  fail "malformed JSON was not refused properly (rc=$rc): $out"
fi

W="$(new_ws refuse-no-jq)"
write_three_findings "$W"
mkdir -p "$TMP_ROOT/emptybin"
out="$( cd "$W" && PATH="$TMP_ROOT/emptybin" "$BASH_BIN" "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'jq is required'; then
  pass "a missing jq is refused with a clear message, and nothing is posted"
else
  fail "a missing jq was not refused properly (rc=$rc): $out"
fi

W="$(new_ws refuse-flag)"
write_three_findings "$W"
out="$( cd "$W" && bash "$SCRIPT" --dry-run --post-everything 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then pass "an unknown flag is refused"; else fail "an unknown flag was accepted"; fi

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "jq-dependent cases (jq not installed)"
  printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  printf 'NOTE: %d case(s) were SKIPPED for a missing binary. A skip is not a pass.\n' "$SKIP"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

W="$(new_ws refuse-empty)"
printf '%s' '{"agent": "review-validator", "category": "validation", "findings": []}' > "$W/.code-review/VALIDATED.json"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'zero findings'; then
  pass "zero findings and no verdict is refused, not treated as an approval"
else
  fail "an empty document was not refused properly (rc=$rc): $out"
fi

W="$(new_ws refuse-floor)"
write_three_findings "$W"
out="$( cd "$W" && CODE_REVIEW_BLOCKING_FLOOR=WHATEVER bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'CODE_REVIEW_BLOCKING_FLOOR'; then
  pass "an invalid CODE_REVIEW_BLOCKING_FLOOR is refused, with the reason"
else
  fail "an invalid floor was not refused properly (rc=$rc): $out"
fi

# --- routing, under --dry-run (no glab call of any kind) -------------------------------------------

W="$(new_ws route)"
write_three_findings "$W"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
payload="$(printf '%s\n' "$out" | sed -n '/^payload:/,$p' | sed '1d')"
if [ "$rc" -ne 0 ]; then
  fail "a well-formed document was refused (rc=$rc): $out"
else
  pass "a well-formed document is accepted under --dry-run"
  if printf '%s' "$out" | grep -q '^  inline  src/auth\.py:42 '; then
    pass "in_diff:true with a parseable location routes INLINE"
  else
    fail "in_diff:true did not route inline: $out"
  fi
  if printf '%s' "$payload" | jq -e '.inline | length == 1 and (.[0].draft.position
      | .new_path == "src/auth.py" and .new_line == 42 and .position_type == "text"
        and has("base_sha") and has("start_sha") and has("head_sha") and has("old_path"))' >/dev/null 2>&1; then
    pass "the payload carries one inline draft whose position has every required field"
  else
    fail "the inline payload is wrong: $payload"
  fi
  if printf '%s' "$payload" | jq -e '(.inline[0].draft | has("note")) and (.summary | has("note"))' >/dev/null 2>&1; then
    pass 'the draft and the bulk_publish summary both use `note`, as those endpoints require'
  else
    fail "the payload field names do not match GitLab's endpoints: $payload"
  fi
  if printf '%s' "$payload" | jq -e '(.summary.note | contains("SEM-002"))
      and (.inline | map(.draft.note) | join(" ") | contains("SEM-002") | not)' >/dev/null 2>&1; then
    pass "in_diff:false routes to the summary and never inline"
  else
    fail "in_diff:false was not confined to the summary: $payload"
  fi
  if printf '%s' "$payload" | jq -e '.summary.note | contains("ARC-003")' >/dev/null 2>&1; then
    pass "a finding whose location will not parse degrades to the summary, and is not dropped"
  else
    fail "a finding with an unparseable location vanished: $payload"
  fi
  if printf '%s' "$payload" | jq -e '(tostring | contains("code-review-core:fp2:src%2Fauth.py:tenant%20id%20is%20not%20part%20of%20the%20cache%20key"))' >/dev/null 2>&1; then
    pass "posted findings carry the fp2 path+title fingerprint marker"
  else
    fail "no fp2 marker in the payload: $payload"
  fi
fi

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

# --- the verdict mapping ---------------------------------------------------------------------------

for pair in REQUEST_CHANGES:REQUEST_CHANGES APPROVE:APPROVE INCOMPLETE:COMMENT; do
  v="${pair%%:*}"; want="${pair#*:}"
  W="$(new_ws "verdict-$v")"
  write_three_findings "$W" "$v"
  got="$( cd "$W" && bash "$SCRIPT" --dry-run 2>/dev/null | sed -n 's/^  review event:   //p' )"
  if [ "$got" = "$want" ]; then pass "$v maps to the $want event"; else fail "$v mapped to '$got', expected $want"; fi
done

W="$(new_ws verdict-incomplete-body)"
write_three_findings "$W" INCOMPLETE
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"
if printf '%s' "$out" | grep -q '^  approve call:   no$' \
   && dry_payload "$W" | jq -e '.summary.note | test("incomplete"; "i")' >/dev/null 2>&1; then
  pass "an INCOMPLETE review says so and plans no approve call"
else
  fail "an INCOMPLETE review was mishandled: $out"
fi

W="$(new_ws verdict-approve-suppressed)"
write_three_findings "$W" APPROVE
out="$( cd "$W" && bash "$SCRIPT" --dry-run --no-approve 2>&1 )"
if printf '%s\n' "$out" | grep -q '^  approve call:   no$'; then
  pass "--no-approve suppresses the approve call even on an APPROVE verdict"
else
  fail "--no-approve did not suppress the approve call: $out"
fi

# --- command injection: finding text is DATA ---------------------------------------------------------

make_glab_stub "$TMP_ROOT/glabbin"

W="$(new_ws injection)"
PWNED="$TMP_ROOT/pwned-$$-injection-marker"
rm -f "$PWNED"
cat > "$W/.code-review/VALIDATED.json" <<JSON
{"agent": "review-validator", "category": "validation", "verdict": "REQUEST_CHANGES",
 "findings": [{"id": "INJ-001", "severity": "BLOCKER", "category": "security", "location": "src/run.sh:3",
   "title": "\$(touch $PWNED)", "evidence": "the script runs \`touch $PWNED\`; rm -rf / #",
   "recommendation": "\$( id > $PWNED ) && echo pwned", "ux_impact": false, "in_diff": true, "confidence": "HIGH"}]}
JSON
payload="$(dry_payload "$W")"
if [ ! -e "$PWNED" ] && printf '%s' "$payload" | jq -e --arg p "$PWNED" \
     '(.inline | map(.draft.note) | join(" ")) | contains("$(touch " + $p + ")") and contains("`touch " + $p + "`")' >/dev/null 2>&1; then
  pass "a command substitution and backticks in a finding stay literal and create no file"
else
  fail "finding text was not carried literally, or was evaluated: $payload"
fi
P="$(new_mr injection)"
mr_round "$W" "$P"
if [ ! -e "$PWNED" ] && [ "$RC" -eq 0 ]; then
  pass "the posting path evaluates no finding text either"
else
  fail "the posting path misbehaved on hostile text (rc=$RC, file exists: $([ -e "$PWNED" ] && echo yes || echo no)): $OUT"
fi

# --- posting, against the stateful stub ------------------------------------------------------------

W="$(new_ws post-first)"; write_three_findings "$W"; P="$(new_mr first)"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e --arg b "$SHA_BASE" --arg s "$SHA_START" --arg h "$SHA_HEAD" \
     '.position.base_sha == $b and .position.start_sha == $s and .position.head_sha == $h' \
     "$P/draftposts.log" >/dev/null 2>&1 \
   && [ "$(jq '[.[] | select(.position != null)] | length' "$P/notes.json")" = "1" ] \
   && [ "$(summary_notes "$P")" = "1" ] && [ ! -s "$P/approve.log" ]; then
  pass "a first run publishes one anchored note and one summary, SHAs from the diff version, no approval"
else
  fail "the first post was wrong (rc=$RC): $OUT"
fi
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/publish.log" ] && [ ! -s "$P/draftposts.log" ] \
   && printf '%s' "$OUT" | grep -q 'nothing new to post'; then
  pass "a re-run over the MR's own notes posts nothing and says so"
else
  fail "a re-run duplicated the review (rc=$RC): $OUT"
fi

W="$(new_ws post-approve)"; write_three_findings "$W" APPROVE; P="$(new_mr approve)"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e --arg h "$SHA_HEAD" '.sha == $h' "$P/approve.log" >/dev/null 2>&1; then
  pass "an APPROVE verdict approves, pinned to the MR head SHA"
else
  fail "an APPROVE verdict did not approve with the sha (rc=$RC): $OUT; $(cat "$P/approve.log")"
fi

W="$(new_ws post-no-diffrefs)"; write_three_findings "$W"; P="$(new_mr nodiffrefs)"
jq '.diff_refs = null' "$P/mr.json" > "$P/t" && mv "$P/t" "$P/mr.json"
mr_round "$W" "$P"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'diff_refs'; then
  pass "an MR with no usable diff_refs is refused, with the reason"
else
  fail "a missing diff_refs was not refused (rc=$RC): $OUT"
fi

W="$(new_ws post-resolve-iid)"; write_three_findings "$W"; P="$(new_mr resolve)"
out="$( cd "$W" && PATH="$TMP_ROOT/glabbin:$PATH" GLAB_STUB_DIR="$P" bash "$SCRIPT" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'merge_requests/7'; then
  pass "the merge request IID is resolved from the current branch when --mr is omitted"
else
  fail "the IID was not resolved (rc=$rc): $out"
fi

W="$(new_ws refuse-no-glab)"; write_three_findings "$W"
out="$( cd "$W" && PATH="$TMP_ROOT/emptybin:$JQ_DIR" "$BASH_BIN" "$SCRIPT" --mr 7 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then pass "a real post with no glab on PATH is refused"; else fail "no glab was accepted"; fi

# --- regressions for the transport review (each fails on the previous script) ------------------------

# R1. The blocking list is blocking_reason_ids, not a re-derivation: the document blocks on a MINOR
#     with ux_impact and not on a MEDIUM-confidence BLOCKER, as the contract does.
W="$(new_ws r1)"
cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "REQUEST_CHANGES", "blocking_floor": "MAJOR",
 "blocking_reason_ids": ["VALIDATED-MINOR-1"],
 "findings": [
  {"id": "VALIDATED-BLOCKER-1", "severity": "BLOCKER", "category": "c", "location": "src/a.py:1",
   "title": "Uncertain blocker", "evidence": "e", "recommendation": "r", "in_diff": true, "ux_impact": false, "confidence": "MEDIUM"},
  {"id": "VALIDATED-MINOR-1", "severity": "MINOR", "category": "c", "location": "src/b.py:2",
   "title": "Visible regression", "evidence": "e", "recommendation": "r", "in_diff": true, "ux_impact": true, "confidence": "HIGH"}]}
JSON
blk="$(dry_payload "$W" | jq -r '.summary.note' | sed -n '/^### Blocking/,/^$/p;/^### Blocking/,/^###/p' | grep '^- ' | sort -u)"
if [ "$(printf '%s\n' "$blk" | grep -c .)" = "1" ] && printf '%s' "$blk" | grep -q 'Visible regression'; then
  pass "R1 the Blocking section is exactly blocking_reason_ids"
else
  fail "R1 the Blocking section re-derived blocking: $blk"
fi

# R2. Renumbered ids: the MR carries a first-version marker for VALIDATED-MAJOR-1 on a DIFFERENT
#     finding. The new VALIDATED-MAJOR-1 must still be posted.
W="$(new_ws r2)"; P="$(new_mr r2)"
vdoc "$W" REQUEST_CHANGES "$(fnd VALIDATED-MAJOR-1 MAJOR errors src/app.py:3 'Unchecked return value')"
printf '%s\n' '[{"id": 10, "author": {"username": "review-bot"}, "body": "**MAJOR / logic** Old unrelated finding\n\ne\n<!-- code-review-core:finding:VALIDATED-MAJOR-1 -->", "position": {"new_path": "src/other.py"}}]' > "$P/notes.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e '.position.new_path == "src/app.py"' "$P/draftposts.log" >/dev/null 2>&1; then
  pass "R2 a finding that inherited a posted id through renumbering is still posted"
else
  fail "R2 a renumbered id hid a new finding (rc=$RC): $OUT"
fi

# R3. The fingerprint, not the id, is the key: the same finding under a new id is not reposted.
W="$(new_ws r3)"; P="$(new_mr r3)"
vdoc "$W" REQUEST_CHANGES "$(fnd VALIDATED-MAJOR-2 MAJOR errors src/app.py:3 'Unchecked return value')"
printf '%s\n' '[{"id": 10, "author": {"username": "review-bot"}, "body": "x <!-- code-review-core:fp2:src%2Fapp.py:unchecked%20return%20value -->"},
 {"id": 11, "author": {"username": "review-bot"}, "body": "## Code review\n\n<!-- code-review-core:verdict:REQUEST_CHANGES -->\n"}]' > "$P/notes.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/draftposts.log" ] && [ ! -s "$P/publish.log" ]; then
  pass "R3 the same finding under a new id is recognised by its fingerprint and not reposted"
else
  fail "R3 a fingerprinted finding was reposted (rc=$RC): $OUT"
fi

# R4. A failed read-back must stop the post; an empty "what is already there" duplicates everything.
for which in notes draft_notes approvals; do
  W="$(new_ws "r4-$which")"; write_three_findings "$W"; P="$(new_mr "r4-$which")"
  mr_round "$W" "$P" GLAB_STUB_FAIL_READ="$which"
  if [ "$RC" -eq 8 ] && [ ! -s "$P/draftposts.log" ] && [ ! -s "$P/publish.log" ]; then
    pass "R4 a failed read of $which refuses to post"
  else
    fail "R4 a failed read of $which did not refuse (rc=$RC): $OUT"
  fi
done

# R5. Stale verdict: every finding is on the MR, but the verdict moved from APPROVE to
#     REQUEST_CHANGES. The new verdict must be posted.
W="$(new_ws r5)"; P="$(new_mr r5)"
vdoc "$W" APPROVE "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
mr_round "$W" "$P" -- --no-approve
vdoc "$W" REQUEST_CHANGES "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
mr_round "$W" "$P" -- --no-approve
if [ "$RC" -eq 0 ] && published_summary "$P" | grep -q 'code-review-core:verdict:REQUEST_CHANGES' \
   && [ "$(summary_notes "$P")" = "2" ]; then
  pass "R5 a changed verdict is posted even when every finding is already on the MR"
else
  fail "R5 the changed verdict was not posted (rc=$RC): $OUT"
fi

# R6. With a verdict present, blocking_floor is the only floor; a disagreeing env value warns.
W="$(new_ws r6)"
cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "APPROVE", "blocking_floor": "BLOCKER",
 "blocking_reason_ids": [], "findings": [{"id": "VALIDATED-MAJOR-1", "severity": "MAJOR", "category": "logic",
   "location": "src/app.py:3", "title": "Off by one", "evidence": "e", "recommendation": "r",
   "ux_impact": false, "in_diff": true, "confidence": "HIGH"}]}
JSON
out="$( cd "$W" && CODE_REVIEW_BLOCKING_FLOOR=MINOR bash "$SCRIPT" --dry-run 2>&1 )"
if printf '%s' "$out" | grep -q 'blocking floor: BLOCKER' && printf '%s' "$out" | grep -q 'is ignored' \
   && ! printf '%s' "$out" | grep -q '### Blocking'; then
  pass "R6 a disagreeing CODE_REVIEW_BLOCKING_FLOOR warns and does not relabel a finalized verdict"
else
  fail "R6 the env floor overrode the document's floor: $out"
fi

# R7. A verdict outside the contract's enum is refused rather than treated as absent.
W="$(new_ws r7)"; vdoc "$W" LGTM "$(fnd A MINOR c src/a.py:1 t)"
out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
if [ "$rc" -eq 5 ]; then pass "R7 an unknown verdict value is refused"; else fail "R7 an unknown verdict was accepted (rc=$rc)"; fi

# R8. No verdict: an uncertain finding escalates (COMMENT), as the contract does.
W="$(new_ws r8)"
printf '%s\n' '{"agent": "a", "category": "VALIDATED", "findings": [{"id": "X", "severity": "BLOCKER", "category": "c",
  "location": "src/a.py:1", "title": "t", "evidence": "e", "recommendation": "r", "in_diff": true, "ux_impact": false,
  "confidence": "MEDIUM"}]}' > "$W/.code-review/VALIDATED.json"
got="$( cd "$W" && bash "$SCRIPT" --dry-run 2>/dev/null | sed -n 's/^  review event:   //p' )"
if [ "$got" = "COMMENT" ]; then pass "R8 without a verdict, an uncertain finding escalates to COMMENT"; else fail "R8 got event '$got'"; fi

# R9. incomplete_inputs, coverage_notes and decision_errors reach the summary.
W="$(new_ws r9)"
printf '%s\n' '{"agent": "a", "category": "VALIDATED", "verdict": "INCOMPLETE", "blocking_floor": "MINOR", "blocking_reason_ids": [],
  "incomplete_inputs": [{"input": "SEMANTIC.json", "problem": "missing"}], "coverage_notes": ["Scanner tools skipped: semgrep."],
  "decision_errors": [{"source_id": "SEM-9", "error": "unknown decision"}], "findings": []}' > "$W/.code-review/VALIDATED.json"
body="$(dry_payload "$W" | jq -r '.summary.note')"
if printf '%s' "$body" | grep -q 'SEMANTIC.json' && printf '%s' "$body" | grep -q 'semgrep' \
   && printf '%s' "$body" | grep -q 'SEM-9'; then
  pass "R9 incomplete_inputs, coverage_notes and decision_errors reach the summary"
else
  fail "R9 the summary omits them: $body"
fi

# R10 (B1). A finding on an UNCHANGED line needs old_line as well as new_line, or GitLab cannot
#     resolve the position. src/auth.py:43 is context (old line 42).
W="$(new_ws r10)"; P="$(new_mr r10)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:43 'Context line problem')"
mr_round "$W" "$P" GLAB_STUB_CONTEXT=src/auth.py:43:42
if [ "$RC" -eq 0 ] && jq -e '.position.old_line == 42 and .position.new_line == 43' "$P/draftposts.log" >/dev/null 2>&1 \
   && [ "$(jq '[.[] | select(.position != null)] | length' "$P/notes.json")" = "1" ]; then
  pass "R10 an unchanged line is anchored with old_line and new_line"
else
  fail "R10 an unchanged line was not anchored (rc=$RC): $OUT"
fi

# R11. A cited line that is not in the diff moves to the summary; the batch still posts.
W="$(new_ws r11)"; P="$(new_mr r11)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'In the diff')" "$(fnd B MAJOR c src/auth.py:90 'Outside the diff')"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ "$(wc -l < "$P/draftposts.log" | tr -d ' ')" = "1" ] \
   && published_summary "$P" | grep -q 'Could not be anchored inline' && published_summary "$P" | grep -q 'Outside the diff'; then
  pass "R11 a line outside the diff moves to the summary instead of failing the batch"
else
  fail "R11 a line outside the diff was mishandled (rc=$RC): $OUT"
fi

# R12. One draft GitLab accepts unanchored (position: null) is deleted and moves to the summary; the
#      other is still published.
W="$(new_ws r12)"; P="$(new_mr r12)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Anchors fine')" "$(fnd B MAJOR c src/run.sh:3 'Will not anchor')"
mr_round "$W" "$P" GLAB_STUB_NULL_PATH=src/run.sh
if [ "$RC" -eq 0 ] && [ -s "$P/deleted.log" ] \
   && [ "$(jq '[.[] | select(.position != null)] | length' "$P/notes.json")" = "1" ] \
   && published_summary "$P" | grep -q 'Will not anchor'; then
  pass "R12 an unanchored draft is deleted and its finding moves to the summary; the rest publish"
else
  fail "R12 an unanchored draft took the batch down or vanished (rc=$RC): $OUT"
fi

# R13. A pending draft of yours would be published by bulk_publish: refuse, publish nothing.
W="$(new_ws r13)"; write_three_findings "$W"; P="$(new_mr r13)"
printf '%s\n' '[{"id": 55, "note": "my half-written human comment", "position": null}]' > "$P/drafts.json"
mr_round "$W" "$P"
if [ "$RC" -eq 10 ] && [ ! -s "$P/publish.log" ] && printf '%s' "$OUT" | grep -q 'draft_notes/<id>'; then
  pass "R13 your own pending drafts are a refusal with the command that clears them"
else
  fail "R13 pending drafts were swept into the post (rc=$RC): $OUT"
fi

# R14. A leftover draft from a killed run is not "posted": it is deleted and the finding is posted.
W="$(new_ws r14)"; write_three_findings "$W"; P="$(new_mr r14)"
printf '%s\n' '[{"id": 56, "note": "old <!-- code-review-core:finding:SEM-001 -->", "position": null}]' > "$P/drafts.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && grep -qx 56 "$P/deleted.log" && [ -s "$P/draftposts.log" ]; then
  pass "R14 a leftover draft of this script is deleted, and its finding is posted for real"
else
  fail "R14 a leftover draft counted as posted (rc=$RC): $OUT"
fi

# R15 (B2). The summary and the reviewer state ride on bulk_publish.
W="$(new_ws r15)"; write_three_findings "$W"; P="$(new_mr r15)"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e '.reviewer_state == "requested_changes" and (.note | startswith("## Code review"))' \
     "$P/publish.log" >/dev/null 2>&1; then
  pass "R15 bulk_publish carries the summary and reviewer_state requested_changes"
else
  fail "R15 bulk_publish did not carry the summary and state (rc=$RC): $(cat "$P/publish.log")"
fi

# R16. An older GitLab that ignores `note` on bulk_publish: the summary is confirmed missing and
#      posted as an ordinary note, once.
W="$(new_ws r16)"; write_three_findings "$W"; P="$(new_mr r16)"
mr_round "$W" "$P" GLAB_STUB_IGNORE_NOTE=1
if [ "$RC" -eq 0 ] && [ "$(summary_notes "$P")" = "1" ]; then
  pass "R16 a summary ignored by bulk_publish is posted as a note, exactly once"
else
  fail "R16 the summary is missing or duplicated ($(summary_notes "$P")) (rc=$RC): $OUT"
fi

# R17 (B3). The inline notes published and the summary failed (exit 12). A re-run must post the
#      summary, even though every finding is already on the MR.
W="$(new_ws r17)"; P="$(new_mr r17)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Only inline')"
mr_round "$W" "$P" GLAB_STUB_SUMMARY_FAIL=1
rc1=$RC
mr_round "$W" "$P"
if [ "$rc1" -eq 12 ] && [ "$RC" -eq 0 ] && [ "$(summary_notes "$P")" = "1" ] \
   && [ "$(jq '[.[] | select(.position != null)] | length' "$P/notes.json")" = "1" ]; then
  pass "R17 after exit 12 a re-run posts the missing summary and no duplicate inline note"
else
  fail "R17 the re-run after exit 12 did not post the summary (rc1=$rc1 rc=$RC): $OUT"
fi

# R18. The MR moved past the reviewed commit: anchor to the reviewed diff version and do not approve.
W="$(new_ws r18)"; P="$(new_mr r18)"
vdoc "$W" APPROVE "$(fnd A MINOR c src/auth.py:42 'Small thing')"
reviewed "$W" "$SHA_OLD"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/approve.log" ] && grep -q "versions/4" "$P/log" \
   && jq -e --arg o "$SHA_OLD" '.position.head_sha == $o' "$P/draftposts.log" >/dev/null 2>&1 \
   && published_summary "$P" | grep -q 'Not approved by this post'; then
  pass "R18 an MR that moved past the reviewed commit is anchored to that commit and not approved"
else
  fail "R18 the reviewed SHA was not honoured (rc=$RC): $OUT"
fi

# R19. The account cannot approve (its own MR, or approval rules): no approve call, stated.
W="$(new_ws r19)"; write_three_findings "$W" APPROVE; P="$(new_mr r19)"
printf '{"user_has_approved": false, "user_can_approve": false}\n' > "$P/approvals.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/approve.log" ] && published_summary "$P" | grep -q 'does not let this account approve'; then
  pass "R19 an account that cannot approve posts the review and says why it did not approve"
else
  fail "R19 an unapprovable MR was mishandled (rc=$RC): $OUT"
fi

# R20. APPROVE, then INCOMPLETE: the standing approval is withdrawn before posting.
W="$(new_ws r20)"; P="$(new_mr r20)"
vdoc "$W" APPROVE "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
mr_round "$W" "$P"
vdoc "$W" INCOMPLETE "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ -s "$P/unapprove.log" ] && jq -e '.user_has_approved == false' "$P/approvals.json" >/dev/null; then
  pass "R20 a standing approval is withdrawn when the verdict becomes INCOMPLETE"
else
  fail "R20 the approval was left standing (rc=$RC): $OUT"
fi

# R21. When the unapprove is refused, stop with the exact command and post nothing.
W="$(new_ws r21)"; P="$(new_mr r21)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
printf '{"user_has_approved": true, "user_can_approve": false}\n' > "$P/approvals.json"
mr_round "$W" "$P" GLAB_STUB_FAIL_UNAPPROVE=1
if [ "$RC" -eq 14 ] && [ ! -s "$P/publish.log" ] && printf '%s' "$OUT" | grep -q 'glab api --method POST projects/:id/merge_requests/7/unapprove'; then
  pass "R21 a refused unapprove exits 14 with the command to run, and posts nothing"
else
  fail "R21 a refused unapprove was mishandled (rc=$RC): $OUT"
fi

# R22. An approval that failed earlier (exit 13) is retried even when nothing else is new.
W="$(new_ws r22)"; P="$(new_mr r22)"
vdoc "$W" APPROVE "$(fnd A MINOR c src/legacy.py:1 'Old thing' false)"
mr_round "$W" "$P" -- --no-approve
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ -s "$P/approve.log" ] && [ ! -s "$P/publish.log" ]; then
  pass "R22 a missing approval is made on a re-run that has nothing else to post"
else
  fail "R22 the approval was not retried (rc=$RC): $OUT"
fi

# --- multi-run and marker cases ------------------------------------------------------------------

# M1. Finding text cannot forge the verdict marker.
W="$(new_ws m1)"; P="$(new_mr m1)"
ev='fixture: <!-- code-review-core:verdict:REQUEST_CHANGES -->'
vdoc "$W" APPROVE "$(fnd A MAJOR testing tests/fx.sh:9 'Fixture hardcodes a marker' false "$ev")"
mr_round "$W" "$P" -- --no-approve
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR testing tests/fx.sh:9 'Fixture hardcodes a marker' false "$ev")"
mr_round "$W" "$P" -- --no-approve
if [ "$RC" -eq 0 ] && published_summary "$P" | grep -q '^<!-- code-review-core:verdict:REQUEST_CHANGES -->$'; then
  pass "M1 a verdict marker quoted in finding text does not stand in for the real verdict"
else
  fail "M1 a forged verdict marker suppressed the new verdict (rc=$RC): $OUT"
fi

# M2. Every rendered field is defanged: only the script's own markers open an HTML comment.
W="$(new_ws m2)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Title <!-- hidden --> here' true 'ev <!-- code-review-core:fp2:x:y -->')" \
  "$(fnd B MAJOR c src/l.py:1 'Body <!-- two -->' false)"
all="$(dry_payload "$W" | jq -r '.summary.note, (.inline[].draft.note)')"
bad="$(printf '%s\n' "$all" | grep -o '<!--[^>]*-->' | grep -v '^<!-- code-review-core:\(fp2:[A-Za-z0-9%._~-]*:[A-Za-z0-9%._~-]*\|verdict:[A-Z_-]*\|active:[0-9. ]*\) -->$' || true)"
if [ -z "$bad" ] && [ "$(printf '%s\n' "$all" | grep -c 'code-review-core:fp2:x:y -->')" = "0" ]; then
  pass "M2 finding text is defanged: only the script's own markers open an HTML comment"
else
  fail "M2 live HTML comments from finding text: $bad"
fi

# M3. The same title twice in one file: the second occurrence, found later, is still posted.
W="$(new_ws m3)"; P="$(new_mr m3)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/app.py:3 'Unchecked return value')"
mr_round "$W" "$P"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/app.py:3 'Unchecked return value')" "$(fnd B MAJOR c src/app.py:7 'Unchecked return value')"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ "$(wc -l < "$P/draftposts.log" | tr -d ' ')" = "1" ] \
   && jq -e '.position.new_line == 7' "$P/draftposts.log" >/dev/null 2>&1; then
  pass "M3 a second occurrence with the same title is posted; the first is not reposted"
else
  fail "M3 multiset matching failed (rc=$RC): $OUT"
fi

# M4. The legacy slugged marker (fp:<category>~<path>~<title>) still counts.
W="$(new_ws m4)"; P="$(new_mr m4)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR errors src/app.py:3 'Unchecked return value')"
printf '%s\n' '[{"id": 10, "author": {"username": "review-bot"}, "body": "x <!-- code-review-core:fp:errors~src/app.py~unchecked-return-value -->"},
 {"id": 11, "author": {"username": "review-bot"}, "body": "## Code review\n\n<!-- code-review-core:verdict:REQUEST_CHANGES -->\n"}]' > "$P/notes.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/draftposts.log" ] && [ ! -s "$P/publish.log" ]; then
  pass "M4 the legacy fp:<category>~<path>~<title> marker is honoured"
else
  fail "M4 a legacy fp marker was ignored (rc=$RC): $OUT"
fi

# M5. A first-version id marker counts when its own entry has the title and location, and does
#     not swallow a different finding whose title it merely contains.
W="$(new_ws m5)"; P="$(new_mr m5)"
vdoc "$W" REQUEST_CHANGES "$(fnd SEM-001 MAJOR errors src/legacy.py:12 'Missing null check' false)" \
  "$(fnd SEM-002 MAJOR errors src/api/handler.py:40 'Missing null check')"
printf '%s\n' '[{"id": 10, "author": {"username": "review-bot"}, "body": "## Code review\n\nVerdict: **REQUEST_CHANGES** - review event `REQUEST_CHANGES`.\n\n- **MAJOR** / errors / `src/legacy.py:12`  \n  Missing null check  \n  <!-- code-review-core:finding:SEM-001 -->\n- **MAJOR** / errors / `src/parser.py:9`  \n  Missing null check in parser  \n  <!-- code-review-core:finding:SEM-002 -->"}]' > "$P/notes.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e '.position.new_path == "src/api/handler.py"' "$P/draftposts.log" >/dev/null 2>&1 \
   && ! published_summary "$P" | grep -q 'src/legacy.py:12'; then
  pass "M5 a legacy id marker counts only for its own entry's title and location"
else
  fail "M5 legacy id matching was wrong (rc=$RC): $OUT"
fi

# M6. Over the size limit: compacted first, then cut at a whole entry with every shown entry marked.
W="$(new_ws m6)"
jq -n '{agent: "a", category: "VALIDATED", verdict: "APPROVE", blocking_floor: "MINOR", blocking_reason_ids: [],
  findings: [range(0; 200) | {id: "F\(.)", severity: "MINOR", category: "c", location: "src/f\(.).py:1",
    title: ("Finding \(.) " + ("t" * 100)), evidence: ("x" * 300), recommendation: "r", in_diff: false, ux_impact: false, confidence: "HIGH"}]}' \
  > "$W/.code-review/VALIDATED.json"
b="$(POST_REVIEW_MAX_BODY=20000 dry_payload "$W" | jq -r '.summary.note')"
n_entries="$(printf '%s\n' "$b" | grep -c '^- \*\*MINOR\*\* / ')"
n_marks="$(printf '%s\n' "$b" | grep -c '<!-- code-review-core:fp2:')"
if [ "${#b}" -le 20000 ] && printf '%s' "$b" | grep -q 'Summary truncated' && ! printf '%s' "$b" | grep -q 'Evidence:' \
   && [ "$n_entries" -gt 0 ] && [ "$n_entries" -eq "$n_marks" ]; then
  pass "M6 an oversized summary is compacted, then cut at a whole entry ($n_marks entries)"
else
  fail "M6 the size limit was not handled (${#b} chars, $n_entries entries, $n_marks markers)"
fi

# M7. The success line counts the markers that landed, and says to re-run for the rest.
P="$(new_mr m7)"
mr_round "$W" "$P" POST_REVIEW_MAX_BODY=20000 -- --no-approve
landed="$(published_summary "$P" | grep -c '<!-- code-review-core:fp2:')"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "0 inline, $landed in the summary" \
   && printf '%s' "$OUT" | grep -q "$((200 - landed)) of 200 summary finding(s) did not fit"; then
  pass "M7 a truncated post reports the $landed findings that landed"
else
  fail "M7 a truncated post misreported what landed ($landed): $OUT"
fi

# M8. The reviewed commit is not one of the MR's diff versions: nothing is anchored, everything
#     reaches the summary, and nothing is approved.
W="$(new_ws m8)"; P="$(new_mr m8)"
vdoc "$W" APPROVE "$(fnd A MINOR c src/auth.py:42 'Small thing')"
reviewed "$W" "$SHA_GONE"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && [ ! -s "$P/draftposts.log" ] && [ ! -s "$P/approve.log" ] \
   && published_summary "$P" | grep -q 'is not one of this merge request'; then
  pass "M8 a reviewed commit GitLab never saw moves every inline finding to the summary and does not approve"
else
  fail "M8 an unknown reviewed commit was mishandled (rc=$RC): $OUT"
fi

# --- the verification pass: each case fails on the script before it -----------------------------

# V1. A re-run of APPROVE on an MR this account already approved. GitLab then reports
#     user_can_approve false (it is "eligible" only while not yet approved), which used to be read
#     as "this account may not approve" and printed in the summary.
W="$(new_ws v1)"; P="$(new_mr v1)"
vdoc "$W" APPROVE "$(fnd A NIT c src/app.py:3 'Nit one')"
mr_round "$W" "$P"
vdoc "$W" APPROVE "$(fnd A NIT c src/app.py:3 'Nit one')" "$(fnd B NIT c src/app.py:5 'Nit two')"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'not approved' \
   && ! published_summary "$P" | grep -q 'Not approved by this post' \
   && jq -e '.user_has_approved == true' "$P/approvals.json" >/dev/null; then
  pass "V1 an approval this account already holds is not reported as refused"
else
  fail "V1 a standing approval was reported as refused (rc=$RC): $OUT"
fi

# V2. GitLab sets reviewer_state only after the summary note is created. When the note fails on
#     bulk_publish (422, drafts already published) the summary is posted as a note, and the state
#     has to be set by a second, draft-less bulk_publish.
W="$(new_ws v2)"; P="$(new_mr v2)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Bug A')"
mr_round "$W" "$P" GLAB_STUB_BP422=1
if [ "$RC" -eq 0 ] && [ "$(cat "$P/reviewer_state" 2>/dev/null)" = "requested_changes" ] \
   && [ "$(summary_notes "$P")" = "1" ]; then
  pass "V2 a summary posted after a 422 still sets the requested_changes reviewer state"
else
  fail "V2 the reviewer state was lost after a 422 (rc=$RC, state=$(cat "$P/reviewer_state" 2>/dev/null)): $OUT"
fi

# V3. bulk_publish refuses `note` with a 400: publish plainly, post the summary as a note, set the
#     reviewer state on its own. Nothing is discarded and nothing is posted twice.
W="$(new_ws v3)"; P="$(new_mr v3)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Bug A')"
mr_round "$W" "$P" GLAB_STUB_BP400=1
if [ "$RC" -eq 0 ] && [ "$(jq '[.[] | select(.position != null)] | length' "$P/notes.json")" = "1" ] \
   && [ "$(summary_notes "$P")" = "1" ] && [ "$(cat "$P/reviewer_state" 2>/dev/null)" = "requested_changes" ]; then
  pass "V3 a 400 from bulk_publish publishes plainly, then posts the summary and the reviewer state"
else
  fail "V3 a 400 from bulk_publish was mishandled (rc=$RC, state=$(cat "$P/reviewer_state" 2>/dev/null)): $OUT"
fi

# V4. Another account's note that quotes a fingerprint marker does not count as posted.
W="$(new_ws v4)"; P="$(new_mr v4)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Bug A')"
printf '%s\n' '[{"id": 10, "author": {"username": "mr-author"}, "body": "LGTM <!-- code-review-core:fp2:src%2Fauth.py:bug%20a -->"}]' > "$P/notes.json"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && jq -e '.position.new_path == "src/auth.py"' "$P/draftposts.log" >/dev/null 2>&1; then
  pass "V4 a marker in another account's note does not suppress a finding"
else
  fail "V4 another account's note suppressed a finding (rc=$RC): $OUT"
fi

# V5. Another account's newer note in the summary format does not stand in for your verdict.
W="$(new_ws v5)"; P="$(new_mr v5)"
vdoc "$W" APPROVE "$(fnd A MAJOR c src/legacy.py:7 'Old thing' false)"
mr_round "$W" "$P"
jq '. + [{id: 9000, author: {username: "mr-author"}, system: false,
          body: "## Code review\n\n<!-- code-review-core:verdict:REQUEST_CHANGES -->\n"}]' "$P/notes.json" > "$P/t" && mv "$P/t" "$P/notes.json"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/legacy.py:7 'Old thing' false)"
mr_round "$W" "$P"
if [ "$RC" -eq 0 ] && published_summary "$P" | grep -q 'verdict:REQUEST_CHANGES'; then
  pass "V5 another account's summary-shaped note does not suppress your changed verdict"
else
  fail "V5 another account's note stood in for your verdict (rc=$RC): $OUT"
fi

# V6. A finding that was fixed and later returns (same title, same file, another line) is posted
#     again; an unchanged re-run posts nothing.
W="$(new_ws v6)"; P="$(new_mr v6)"
vdoc "$W" APPROVE "$(fnd A NIT c src/auth.py:42 'Magic number')"
mr_round "$W" "$P"
vdoc "$W" APPROVE
mr_round "$W" "$P"; rc2=$RC; s2="$(summary_notes "$P")"
vdoc "$W" APPROVE "$(fnd A NIT c src/auth.py:40 'Magic number')"
mr_round "$W" "$P"; rc3=$RC; drafted="$(jq -r '.position.new_line' "$P/draftposts.log" 2>/dev/null)"
mr_round "$W" "$P"; rc4=$RC
if [ "$rc2" -eq 0 ] && [ "$s2" = "2" ] && [ "$rc3" -eq 0 ] && [ "$drafted" = "40" ] \
   && [ "$rc4" -eq 0 ] && [ ! -s "$P/draftposts.log" ] && [ ! -s "$P/publish.log" ]; then
  pass "V6 a fixed finding that returns is posted again, and an unchanged re-run posts nothing"
else
  fail "V6 the open set was not honoured (rc=$rc2/$rc3/$RC, summaries=$s2, drafted=$drafted): $OUT"
fi

# V7. A run whose summary failed (exit 12) leaves inline notes newer than the last summary; they
#     count on the re-run even though that summary's open set does not name them.
W="$(new_ws v7)"; P="$(new_mr v7)"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Bug A')"
mr_round "$W" "$P"
vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR c src/auth.py:42 'Bug A')" "$(fnd B MAJOR c src/app.py:3 'Bug B')"
mr_round "$W" "$P" GLAB_STUB_SUMMARY_FAIL=1; rc1=$RC
mr_round "$W" "$P"
if [ "$rc1" -eq 12 ] && [ "$RC" -eq 0 ] && [ ! -s "$P/draftposts.log" ] && [ "$(summary_notes "$P")" = "2" ]; then
  pass "V7 inline notes from a run whose summary failed are not reposted"
else
  fail "V7 a re-run after exit 12 reposted or lost notes (rc1=$rc1 rc=$RC): $OUT"
fi

# V8. An MR posted before the open set existed: an unchanged re-run posts nothing, and a fixed
#     finding makes a summary that records the open set.
W="$(new_ws v8)"; P="$(new_mr v8)"
printf '%s\n' '[{"id": 10, "author": {"username": "review-bot"}, "body": "x <!-- code-review-core:fp2:src%2Fapp.py:unchecked%20return%20value -->"},
 {"id": 11, "author": {"username": "review-bot"}, "body": "## Code review\n\n<!-- code-review-core:verdict:APPROVE -->\n"}]' > "$P/notes.json"
vdoc "$W" APPROVE "$(fnd A NIT c src/app.py:3 'Unchecked return value')"
mr_round "$W" "$P"; rc1=$RC; pub1="$(wc -c < "$P/publish.log")"
vdoc "$W" APPROVE
mr_round "$W" "$P"
if [ "$rc1" -eq 0 ] && [ "$pub1" -eq 0 ] && [ "$RC" -eq 0 ] \
   && published_summary "$P" | grep -q '^<!-- code-review-core:active: -->$'; then
  pass "V8 an MR without an open set is not reposted, and records one once a finding closes"
else
  fail "V8 an MR without an open set was mishandled (rc1=$rc1 pub1=$pub1 rc=$RC): $OUT"
fi

# --- portability: the script must also run under zsh --------------------------------------------------

if ! command -v zsh >/dev/null 2>&1; then
  skip "zsh portability case (zsh not installed)"
else
  W="$(new_ws zsh-port)"; write_three_findings "$W"; P="$(new_mr zsh)"
  out="$( cd "$W" && zsh "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  out2="$( cd "$W" && PATH="$TMP_ROOT/glabbin:$PATH" GLAB_STUB_DIR="$P" zsh "$SCRIPT" --mr 7 2>&1 )"; rc2=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^  inline  src/auth\.py:42 ' && [ "$rc2" -eq 0 ] && [ -s "$P/publish.log" ]; then
    pass "post-review.sh routes and posts the same way under zsh"
  else
    fail "post-review.sh misbehaves under zsh (rc=$rc/$rc2): $out $out2"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$SKIP" -gt 0 ]; then
  printf 'NOTE: %d case(s) were SKIPPED for a missing binary. A skip is not a pass.\n' "$SKIP"
fi
[ "$FAIL" -eq 0 ]
