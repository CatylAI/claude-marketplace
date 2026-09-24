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
# network. Fixture knobs (all optional):
#   GH_STUB_COMMENTS / GH_STUB_REVIEWS  JSON arrays already "on the PR" (default: [])
#   GH_STUB_PR                          the pull request object (default: author "pr-author")
#   GH_STUB_USER                        login `gh api user` returns (default: "review-bot")
#   GH_STUB_FAIL_READ=comments|reviews  make that read fail, as a 5xx or a revoked token would
#   GH_STUB_REJECT_INLINE=1             answer HTTP 422 to any review payload that has comments
#   GH_STUB_PAYLOAD                     where the last ACCEPTED payload is written
#   GH_STUB_DISMISSED                   file each dismissal endpoint (PUT) is appended to
#   GH_STUB_FAIL_DISMISS=1              answer HTTP 403 to a dismissal, as a protected branch would
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
    posting=0; putting=0; input=""; prev=""; endpoint=""
    for a in "$@"; do
      if [ "$prev" = "--method" ] && [ "$a" = "POST" ]; then posting=1; fi
      if [ "$prev" = "--method" ] && [ "$a" = "PUT" ]; then putting=1; fi
      if [ "$prev" = "--input" ]; then input="$a"; fi
      case "$a" in repos/*|user) endpoint="$a" ;; esac
      prev="$a"
    done
    if [ "$putting" -eq 1 ]; then
      if [ "${GH_STUB_FAIL_DISMISS:-0}" = "1" ]; then
        printf 'gh: Must have admin rights to Repository. (HTTP 403)\n' >&2
        exit 1
      fi
      printf '%s\n' "$endpoint" >> "${GH_STUB_DISMISSED:-/dev/null}"
      printf '%s\n' '{"id": 1, "state": "DISMISSED"}'
      exit 0
    fi
    if [ "$posting" -eq 1 ]; then
      if [ "${GH_STUB_REJECT_INLINE:-0}" = "1" ] && jq -e 'has("comments")' "$input" >/dev/null 2>&1; then
        printf 'gh: Validation Failed (HTTP 422)\n' >&2
        exit 1
      fi
      cat "$input" > "${GH_STUB_PAYLOAD:-/dev/null}"
      printf '%s\n' '{"id": 1, "state": "SUBMITTED", "html_url": "https://example.invalid/pull/7#review-1"}'
      exit 0
    fi
    case "$endpoint" in
      user) printf '%s\n' "${GH_STUB_USER:-review-bot}" ;;
      */comments)
        [ "${GH_STUB_FAIL_READ:-}" = "comments" ] && { printf 'gh: Server Error (HTTP 502)\n' >&2; exit 1; }
        if [ -n "${GH_STUB_COMMENTS:-}" ]; then cat "$GH_STUB_COMMENTS"; else printf '[]\n'; fi ;;
      */reviews)
        [ "${GH_STUB_FAIL_READ:-}" = "reviews" ] && { printf 'gh: Server Error (HTTP 502)\n' >&2; exit 1; }
        if [ -n "${GH_STUB_REVIEWS:-}" ]; then cat "$GH_STUB_REVIEWS"; else printf '[]\n'; fi ;;
      repos/*/pulls/*)
        if [ -n "${GH_STUB_PR:-}" ]; then cat "$GH_STUB_PR"
        else printf '%s\n' '{"number": 7, "user": {"login": "pr-author"}, "head": {"sha": "1111111111111111111111111111111111111111"}}'; fi ;;
      *) printf 'gh stub: unsupported api call: %s\n' "$*" >&2; exit 1 ;;
    esac
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

    # Each posted finding carries its stable marker - the thing a re-run greps for. The format is
    # a contract (review-transport documents it and gitlab-workflow mirrors it), so it is pinned.
    if printf '%s' "$payload" | jq -e '.comments[0].body | contains("<!-- code-review-core:fp2:src%2Fauth.py:tenant%20id%20is%20not%20part%20of%20the%20cache%20key -->")' >/dev/null 2>&1; then
      pass "posted findings carry a path+title fingerprint marker for idempotency"
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
  LOG="$TMP_ROOT/first.log"; PAY="$TMP_ROOT/first-payload.json"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$LOG" GH_STUB_PAYLOAD="$PAY" \
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

  # Second run over THIS script's own output: the first run's payload is fed back as what is on the
  # PR (inline bodies as review comments, the body as a CHANGES_REQUESTED review). Nothing is new.
  W="$(new_ws post-second)"
  write_three_findings "$W"
  jq '[.comments[]? | {body, path, user: {login: "review-bot"}, pull_request_review_id: 1}]' "$PAY" > "$TMP_ROOT/own-comments.json"
  jq '[{id: 1, state: "CHANGES_REQUESTED", user: {login: "review-bot"}, body: .body}]' "$PAY" > "$TMP_ROOT/own-reviews.json"
  LOG2="$TMP_ROOT/second.log"; PAY2="$TMP_ROOT/second-payload.json"
  : > "$PAY2"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$LOG2" GH_STUB_PAYLOAD="$PAY2" \
          GH_STUB_COMMENTS="$TMP_ROOT/own-comments.json" GH_STUB_REVIEWS="$TMP_ROOT/own-reviews.json" \
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

  # Markers written by the previous version (`finding:<id>`, next to the title) still count, so an
  # existing PR does not get a duplicate review on its first re-post after the upgrade.
  W="$(new_ws post-legacy)"
  write_three_findings "$W"
  cat > "$TMP_ROOT/legacy-comments.json" <<'LEGACY'
[{"path": "src/auth.py", "user": {"login": "review-bot"}, "body": "**BLOCKER / authz** Tenant id is not part of the cache key\n\n<!-- code-review-core:finding:SEM-001 -->"}]
LEGACY
  cat > "$TMP_ROOT/legacy-reviews.json" <<'LEGACY'
[{"id": 3, "state": "CHANGES_REQUESTED", "user": {"login": "review-bot"}, "body": "## Code review\n- **MAJOR** / errors / `src/legacy.py:7`  \n  Bare except swallows KeyboardInterrupt  \n  <!-- code-review-core:finding:SEM-002 -->\n- **MINOR** / design / `the module as a whole`  \n  Module has two responsibilities  \n  <!-- code-review-core:finding:ARC-003 -->"}]
LEGACY
  PAYL="$TMP_ROOT/legacy-payload.json"; : > "$PAYL"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYL" \
          GH_STUB_COMMENTS="$TMP_ROOT/legacy-comments.json" GH_STUB_REVIEWS="$TMP_ROOT/legacy-reviews.json" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$PAYL" ] && printf '%s' "$out" | grep -q 'nothing new to post'; then
    pass "legacy finding:<id> markers from the previous version are honoured on the first re-post"
  else
    fail "a PR carrying legacy markers got a duplicate review (rc=$rc): $out $(cat "$PAYL")"
  fi

  # A partial re-run: two of three findings already present, so exactly one is new.
  W="$(new_ws post-partial)"
  write_three_findings "$W"
  jq '[.[0] | .body |= (split("\n- **BLOCKER**")[0])]' "$TMP_ROOT/legacy-reviews.json" > "$TMP_ROOT/partial-reviews.json"
  PAY3="$TMP_ROOT/third-payload.json"; : > "$PAY3"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" \
          GH_STUB_LOG="$TMP_ROOT/third.log" GH_STUB_PAYLOAD="$PAY3" \
          GH_STUB_REVIEWS="$TMP_ROOT/partial-reviews.json" \
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

# --- the floor the verdict was computed at ---------------------------------------------------------
# `contract.py finalize --floor BLOCKER` records `blocking_floor: BLOCKER` and APPROVEs a MAJOR. This
# script used to default its own floor to MINOR, so it posted that APPROVE with the MAJOR listed under
# "Blocking". The document's floor is now the default; an explicit env value still wins, as --help says.
if [ "$HAVE_JQ" -eq 0 ]; then
  skip "document blocking_floor default (jq not installed)"
else
  W="$(new_ws doc-floor)"
  cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "APPROVE", "blocking_floor": "BLOCKER",
 "blocking_reason_ids": [], "metrics": {"total": 1, "blocker": 0, "major": 1, "minor": 0, "nit": 0},
 "findings": [{"id": "VALIDATED-MAJOR-1", "severity": "MAJOR", "category": "logic",
   "location": "src/app.py:3", "title": "Off by one", "evidence": "e", "recommendation": "r",
   "ux_impact": false, "in_diff": true, "confidence": "HIGH"}]}
JSON
  out="$( cd "$W" && env -u CODE_REVIEW_BLOCKING_FLOOR bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'blocking floor: BLOCKER' \
     && ! printf '%s' "$out" | grep -q 'Blocking - at or above'; then
    pass "with no env floor, the document's blocking_floor decides the blocking list"
  else
    fail "an APPROVE finalized at BLOCKER still lists a MAJOR as blocking (rc=$rc): $out"
  fi
  # With a verdict present the document's floor is the only floor. A disagreeing env value used to
  # relabel the blocking list; it now warns on stderr and changes nothing.
  out="$( cd "$W" && CODE_REVIEW_BLOCKING_FLOOR=MINOR bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'blocking floor: BLOCKER' \
     && printf '%s' "$out" | grep -q 'CODE_REVIEW_BLOCKING_FLOOR=MINOR is ignored' \
     && ! printf '%s' "$out" | grep -q 'Blocking - '; then
    pass "a disagreeing CODE_REVIEW_BLOCKING_FLOOR warns and does not relabel a finalized verdict"
  else
    fail "the env floor relabelled a finalized verdict, or said nothing (rc=$rc): $out"
  fi
fi

# --- regressions for the transport review (each fails on the previous script) ------------------------

dry_payload() { # <workspace> [extra args...] -> prints the dry-run payload JSON
  _w="$1"; shift
  ( cd "$_w" && bash "$SCRIPT" --dry-run "$@" 2>/dev/null ) | sed -n '/^payload:/,$p' | sed '1d'
}

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "transport regressions (jq not installed)"
else
  make_gh_stub "$TMP_ROOT/ghbin"

  # R1. The blocking list is blocking_reason_ids, not a re-derivation. The document blocks on a
  #     MINOR with ux_impact (the contract blocks those at any floor) and does NOT block on a
  #     MEDIUM-confidence BLOCKER (the contract escalates those). The old predicate had both wrong.
  W="$(new_ws r1-reasons)"
  cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "REQUEST_CHANGES", "blocking_floor": "MAJOR",
 "blocking_reason_ids": ["VALIDATED-MINOR-1"],
 "findings": [
  {"id": "VALIDATED-BLOCKER-1", "severity": "BLOCKER", "category": "logic", "location": "a.py:1",
   "title": "Unsure null deref", "evidence": "e", "recommendation": "r", "ux_impact": false, "in_diff": true, "confidence": "MEDIUM"},
  {"id": "VALIDATED-MINOR-1", "severity": "MINOR", "category": "ux", "location": "b.py:2",
   "title": "Error message shown raw to users", "evidence": "e", "recommendation": "r", "ux_impact": true, "in_diff": true, "confidence": "HIGH"}]}
JSON
  body="$(dry_payload "$W" | jq -r '.body')"
  blk="$(printf '%s\n' "$body" | sed -n '/^### Blocking/,/^### [^B]/p')"
  if printf '%s' "$blk" | grep -q 'Error message shown raw' && ! printf '%s' "$blk" | grep -q 'Unsure null deref'; then
    pass "the Blocking section is exactly blocking_reason_ids"
  else
    fail "the Blocking section was re-derived instead of read from blocking_reason_ids: $body"
  fi

  # R2. Renumbered ids. The PR carries a legacy marker for VALIDATED-MAJOR-1 on a DIFFERENT finding
  #     ("Old defect", since fixed). The current VALIDATED-MAJOR-1 is new and must be posted.
  W="$(new_ws r2-renumbered)"
  cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "REQUEST_CHANGES", "blocking_floor": "MINOR",
 "blocking_reason_ids": ["VALIDATED-MAJOR-1"],
 "findings": [{"id": "VALIDATED-MAJOR-1", "severity": "MAJOR", "category": "logic", "location": "src/new.py:9",
   "title": "New defect", "evidence": "e", "recommendation": "r", "ux_impact": false, "in_diff": true, "confidence": "HIGH"}]}
JSON
  printf '%s\n' '[{"body": "**MAJOR / logic** Old defect\n\n<!-- code-review-core:finding:VALIDATED-MAJOR-1 -->"}]' > "$TMP_ROOT/r2-comments.json"
  printf '%s\n' '[{"id": 5, "state": "CHANGES_REQUESTED", "body": "## Code review <!-- code-review-core:finding:VALIDATED-MAJOR-1 --> Old defect"}]' > "$TMP_ROOT/r2-reviews.json"
  PAYR="$TMP_ROOT/r2-payload.json"; : > "$PAYR"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYR" \
          GH_STUB_COMMENTS="$TMP_ROOT/r2-comments.json" GH_STUB_REVIEWS="$TMP_ROOT/r2-reviews.json" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.comments[0].body | contains("New defect")' "$PAYR" >/dev/null 2>&1; then
    pass "a finding that inherited a posted id through renumbering is still posted"
  else
    fail "a renumbered finding was silently skipped (rc=$rc): $out"
  fi

  # R3. The fingerprint, not the id, is the key: the same finding under a new id is not reposted.
  W="$(new_ws r3-fingerprint)"
  sed 's/"VALIDATED-MAJOR-1"/"VALIDATED-MAJOR-4"/g' "$TMP_ROOT/r2-renumbered/.code-review/VALIDATED.json" \
    > "$W/.code-review/VALIDATED.json"
  jq '[.comments[] | {body, path, user: {login: "review-bot"}, pull_request_review_id: 6}]' "$PAYR" > "$TMP_ROOT/r3-comments.json"
  jq '[{id: 6, state: "CHANGES_REQUESTED", user: {login: "review-bot"}, body: .body}]' "$PAYR" > "$TMP_ROOT/r3-reviews.json"
  PAYF="$TMP_ROOT/r3-payload.json"; : > "$PAYF"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYF" \
          GH_STUB_COMMENTS="$TMP_ROOT/r3-comments.json" GH_STUB_REVIEWS="$TMP_ROOT/r3-reviews.json" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$PAYF" ]; then
    pass "the same finding under a new id is recognised by its fingerprint and not reposted"
  else
    fail "a finding was reposted only because its id changed (rc=$rc): $out $(cat "$PAYF")"
  fi

  # R4. A failed read-back must stop the post; an empty "what is already there" duplicates everything.
  for which in comments reviews; do
    W="$(new_ws "r4-$which")"
    write_three_findings "$W"
    PAYX="$TMP_ROOT/r4-$which.json"; : > "$PAYX"
    out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYX" GH_STUB_FAIL_READ="$which" \
            bash "$SCRIPT" 2>&1 )"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$PAYX" ]; then
      pass "a failed read of existing $which refuses to post"
    else
      fail "a failed read of existing $which still posted (rc=$rc): $out"
    fi
  done

  # R5. Stale verdict: every finding is already on the PR, but the verdict moved from
  #     REQUEST_CHANGES to APPROVE. The PR must hear about it.
  W="$(new_ws r5-verdict)"
  write_three_findings "$W" APPROVE
  PAYV="$TMP_ROOT/r5-payload.json"; : > "$PAYV"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYV" \
          GH_STUB_COMMENTS="$TMP_ROOT/own-comments.json" GH_STUB_REVIEWS="$TMP_ROOT/own-reviews.json" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.event == "APPROVE" and ((.comments // []) | length == 0)' "$PAYV" >/dev/null 2>&1; then
    pass "a changed verdict is posted even when every finding is already on the PR"
  else
    fail "a changed verdict was not posted (rc=$rc): $out"
  fi

  # R6. Self-authored PR: GitHub rejects APPROVE / REQUEST_CHANGES from the author. Downgrade to
  #     COMMENT and say what the verdict was.
  W="$(new_ws r6-self)"
  write_three_findings "$W"
  PAYS="$TMP_ROOT/r6-payload.json"; : > "$PAYS"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYS" GH_STUB_USER="pr-author" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && jq -e '.event == "COMMENT" and (.body | contains("REQUEST_CHANGES")) and (.body | contains("own pull request"))' "$PAYS" >/dev/null 2>&1; then
    pass "on the author's own PR the verdict posts as COMMENT and is stated in the body"
  else
    fail "a self-authored PR got an event GitHub rejects (rc=$rc): $out $(cat "$PAYS")"
  fi

  # R7. --no-approve turns APPROVE into COMMENT and leaves REQUEST_CHANGES alone.
  W="$(new_ws r7-noapprove)"
  write_three_findings "$W" APPROVE
  ev="$(dry_payload "$W" --no-approve | jq -r '.event' 2>/dev/null)"
  W2="$(new_ws r7-noapprove-rc)"
  write_three_findings "$W2" REQUEST_CHANGES
  ev2="$(dry_payload "$W2" --no-approve | jq -r '.event' 2>/dev/null)"
  if [ "$ev" = "COMMENT" ] && [ "$ev2" = "REQUEST_CHANGES" ]; then
    pass "--no-approve posts APPROVE as COMMENT and leaves REQUEST_CHANGES alone"
  else
    fail "--no-approve gave '$ev' for APPROVE and '$ev2' for REQUEST_CHANGES"
  fi

  # R8. A 422 on the inline comments falls back to one body-only review; nothing is dropped.
  W="$(new_ws r8-422)"
  write_three_findings "$W"
  PAY4="$TMP_ROOT/r8-payload.json"; : > "$PAY4"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAY4" GH_STUB_REJECT_INLINE=1 \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 0 ] && jq -e '(has("comments") | not) and (.body | contains("Tenant id is not part of the cache key")) and (.body | contains("Could not be anchored inline"))' "$PAY4" >/dev/null 2>&1; then
    pass "a 422 on inline comments retries once with those findings in the body"
  else
    fail "a 422 on inline comments lost the review (rc=$rc): $out"
  fi

  # R9. Inline comments are anchored to the reviewed commit from CONTEXT.json.
  W="$(new_ws r9-commit)"
  write_three_findings "$W"
  printf '%s\n' '{"reviewed_sha": "abcdefabcdefabcdefabcdefabcdefabcdefabcd"}' > "$W/.code-review/CONTEXT.json"
  if dry_payload "$W" | jq -e '.commit_id == "abcdefabcdefabcdefabcdefabcdefabcdefabcd"' >/dev/null 2>&1; then
    pass "the payload's commit_id is the reviewed commit"
  else
    fail "the payload is not anchored to the reviewed commit: $(dry_payload "$W")"
  fi

  # R10. An INCOMPLETE forced by a missing input names that input on the PR.
  W="$(new_ws r10-inputs)"
  cat > "$W/.code-review/VALIDATED.json" <<'JSON'
{"agent": "review-validator", "category": "VALIDATED", "verdict": "INCOMPLETE", "blocking_floor": "MINOR",
 "blocking_reason_ids": [], "incomplete_inputs": [{"input": "SEMANTIC.json", "problem": "is missing"}],
 "coverage_notes": ["Scanner tools skipped: semgrep."], "findings": []}
JSON
  if dry_payload "$W" | jq -e '.event == "COMMENT" and (.body | contains("SEMANTIC.json")) and (.body | contains("semgrep"))' >/dev/null 2>&1; then
    pass "incomplete_inputs and coverage_notes reach the review body"
  else
    fail "the review body hides why the review is incomplete: $(dry_payload "$W")"
  fi

  # R11. An unsubmitted pending review of your own makes GitHub reject a new one: refuse, with the fix.
  W="$(new_ws r11-pending)"
  write_three_findings "$W"
  printf '%s\n' '[{"id": 99, "state": "PENDING", "body": ""}]' > "$TMP_ROOT/r11-reviews.json"
  PAYP="$TMP_ROOT/r11-payload.json"; : > "$PAYP"
  out="$( cd "$W" && PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$PAYP" GH_STUB_REVIEWS="$TMP_ROOT/r11-reviews.json" \
          bash "$SCRIPT" 2>&1 )"; rc=$?
  if [ "$rc" -eq 10 ] && [ ! -s "$PAYP" ] && printf '%s' "$out" | grep -q 'reviews/99'; then
    pass "an existing pending review is refused with the command that clears it"
  else
    fail "a pending review was not handled (rc=$rc): $out"
  fi

  # R12 moved to M13 below: its fixture never reached the cap, so it passed with the cap removed.

  # R13. A verdict outside the contract's enum is refused rather than treated as absent.
  W="$(new_ws r13-verdict)"
  write_three_findings "$W" LGTM
  out="$( cd "$W" && bash "$SCRIPT" --dry-run 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "verdict 'LGTM'"; then
    pass "an unknown verdict value is refused"
  else
    fail "an unknown verdict was accepted (rc=$rc): $out"
  fi

  # R14. No verdict: the derived event follows the contract, so a MEDIUM-confidence finding
  #      escalates (COMMENT) instead of requesting changes.
  W="$(new_ws r14-derived)"
  printf '%s\n' '{"agent": "x", "category": "y", "findings": [{"id": "A", "severity": "MAJOR", "category": "logic",
    "location": "a.py:1", "title": "t", "evidence": "e", "recommendation": "r", "ux_impact": false,
    "in_diff": true, "confidence": "MEDIUM"}]}' > "$W/.code-review/VALIDATED.json"
  ev="$(dry_payload "$W" | jq -r '.event' 2>/dev/null)"
  if [ "$ev" = "COMMENT" ]; then
    pass "without a verdict, an uncertain finding escalates to COMMENT, as the contract does"
  else
    fail "without a verdict, an uncertain finding produced '$ev'"
  fi
fi

# --- multi-run cases: the PR remembers what earlier runs posted -----------------------------------
# These replay a sequence of reviews against one simulated pull request. `pr_round` runs a real post
# against the state in <dir>, then appends what the stub accepted (the review, as this account, and
# its inline comments) and applies any dismissal, the way GitHub would.

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
pr_round() { # <workspace> <state-dir> [VAR=value...] -> sets ROUND_OUT, ROUND_RC, ROUND_PAY
  _w="$1"; _d="$2"; shift 2
  [ -f "$_d/reviews.json" ] || printf '[]\n' > "$_d/reviews.json"
  [ -f "$_d/comments.json" ] || printf '[]\n' > "$_d/comments.json"
  ROUND_PAY="$_d/payload.json"; : > "$ROUND_PAY"; : > "$_d/dismissed"
  ROUND_OUT="$( cd "$_w" && env PATH="$TMP_ROOT/ghbin:$PATH" GH_STUB_PAYLOAD="$ROUND_PAY" \
                GH_STUB_REVIEWS="$_d/reviews.json" GH_STUB_COMMENTS="$_d/comments.json" \
                GH_STUB_DISMISSED="$_d/dismissed" "$@" bash "$SCRIPT" 2>&1 )"; ROUND_RC=$?
  for _id in $(sed -n 's#.*/reviews/\([0-9]*\)/dismissals$#\1#p' "$_d/dismissed"); do
    jq --argjson i "$_id" 'map(if .id == $i then .state = "DISMISSED" else . end)' "$_d/reviews.json" > "$_d/t" \
      && mv "$_d/t" "$_d/reviews.json"
  done
  if [ -s "$ROUND_PAY" ]; then
    jq --slurpfile p "$ROUND_PAY" '. + [{id: (length + 100), user: {login: "review-bot"}, body: $p[0].body,
        state: ({"APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED", "COMMENT": "COMMENTED"}[$p[0].event])}]' \
      "$_d/reviews.json" > "$_d/t" && mv "$_d/t" "$_d/reviews.json"
    _rid="$(jq '.[-1].id' "$_d/reviews.json")"
    jq --slurpfile p "$ROUND_PAY" --argjson r "$_rid" '. + [($p[0].comments // [])[]
        | {body, path, line, user: {login: "review-bot"}, pull_request_review_id: $r}]' \
      "$_d/comments.json" > "$_d/t" && mv "$_d/t" "$_d/comments.json"
  fi
}
new_pr() { d="$TMP_ROOT/pr-$1"; mkdir -p "$d"; printf '%s' "$d"; }

if [ "$HAVE_JQ" -eq 0 ]; then
  skip "multi-run cases (jq not installed)"
else
  make_gh_stub "$TMP_ROOT/ghbin"

  # M1. Finding text cannot forge the verdict marker. Run 1 APPROVEs with a pre-existing finding
  #     whose evidence quotes a REQUEST_CHANGES marker; run 2 is REQUEST_CHANGES with nothing new.
  #     The forged marker used to be read as the last verdict, so the approval was left standing.
  W="$(new_ws m1)"; P="$(new_pr m1)"
  ev='fixture: <!-- code-review-core:verdict:REQUEST_CHANGES -->'
  vdoc "$W" APPROVE "$(fnd A MAJOR testing tests/fx.sh:9 'Fixture hardcodes a marker' false "$ev")"
  pr_round "$W" "$P"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR testing tests/fx.sh:9 'Fixture hardcodes a marker' true "$ev")"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '.event == "REQUEST_CHANGES"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "a verdict marker quoted in finding text does not stand in for the real verdict"
  else
    fail "a forged verdict marker suppressed REQUEST_CHANGES (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M2. Every rendered field is defanged: no finding text reaches the PR as a live HTML comment. The
  #     four that remain are the script's own: verdict, open set, and one fp2 marker per finding.
  W="$(new_ws m2)"
  vdoc "$W" REQUEST_CHANGES \
    "$(fnd A MAJOR x src/a.py:1 'Title <!-- code-review-core:fp2:planted:x --> end' true 'ev --> <!--')" \
    "$(fnd B MINOR 'cat<!--' 'docs/b.md:2' 'Pre-existing <!-- open' false '<!-- code-review-core:fp:a~b~c -->')"
  pl="$(dry_payload "$W")"
  if printf '%s' "$pl" | jq -e '[.. | strings | scan("<!--")] | length == 4' >/dev/null 2>&1 \
     && printf '%s' "$pl" | jq -e '[.. | strings | scan("code-review-core:fp2:planted")] | length == 1' >/dev/null 2>&1; then
    pass "finding text is defanged: only the script's own markers open an HTML comment"
  else
    fail "finding text reached the payload as live HTML-comment syntax: $pl"
  fi

  # M3. APPROVE, then an INCOMPLETE run: a COMMENT does not replace an approval on GitHub, so the
  #     earlier approval is dismissed before the comment is posted.
  W="$(new_ws m3)"; P="$(new_pr m3)"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"
  vdoc "$W" INCOMPLETE
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && grep -q 'reviews/100/dismissals' "$P/dismissed" \
     && jq -e '.event == "COMMENT"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "an earlier APPROVE is dismissed when the verdict becomes INCOMPLETE"
  else
    fail "an INCOMPLETE run left the earlier approval standing (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M4. When the dismissal is refused (a protected branch), stop with the command, post nothing.
  W="$(new_ws m4)"; P="$(new_pr m4)"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"
  vdoc "$W" INCOMPLETE
  pr_round "$W" "$P" GH_STUB_FAIL_DISMISS=1
  if [ "$ROUND_RC" -eq 11 ] && [ ! -s "$ROUND_PAY" ] \
     && printf '%s' "$ROUND_OUT" | grep -q 'gh api --method PUT repos/.*/reviews/100/dismissals'; then
    pass "a refused dismissal exits 11 with the command to run, and posts nothing"
  else
    fail "a refused dismissal was not reported (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M5. REQUEST_CHANGES after APPROVE needs no dismissal: the new review replaces the approval.
  W="$(new_ws m5)"; P="$(new_pr m5)"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR x src/a.py:3 'Bug')"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && [ ! -s "$P/dismissed" ] && jq -e '.event == "REQUEST_CHANGES"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "REQUEST_CHANGES after APPROVE posts without dismissing"
  else
    fail "REQUEST_CHANGES after APPROVE went wrong (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M6. A dismissed approval (for example by "dismiss stale approvals" on push) is not a standing
  #     verdict: the next APPROVE run posts it again.
  W="$(new_ws m6)"; P="$(new_pr m6)"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"
  jq 'map(.state = "DISMISSED")' "$P/reviews.json" > "$P/t" && mv "$P/t" "$P/reviews.json"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '.event == "APPROVE"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "a dismissed approval is re-posted by the next APPROVE run"
  else
    fail "a dismissed approval was treated as still standing (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M7. Another account's review is not yours: its verdict does not stand in for your own.
  W="$(new_ws m7)"; P="$(new_pr m7)"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR x src/a.py:3 'Bug')"
  pr_round "$W" "$P"
  jq 'map(.user.login = "someone-else")' "$P/reviews.json" > "$P/t" && mv "$P/t" "$P/reviews.json"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '.event == "REQUEST_CHANGES" and ((.comments // []) | length == 0)' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "another account's review does not count as your verdict (findings are still not reposted)"
  else
    fail "another account's review suppressed your verdict (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M8. The same problem at a second line of the same file, found on a later run, is posted. The key
  #     has no line, so the match is a multiset: one marker accounts for one finding.
  W="$(new_ws m8)"; P="$(new_pr m8)"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR shell deploy.sh:10 'Unquoted variable expansion')"
  pr_round "$W" "$P"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR shell deploy.sh:10 'Unquoted variable expansion')" \
                            "$(fnd B MAJOR shell deploy.sh:44 'Unquoted variable expansion')"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '(.comments | length == 1) and (.comments[0].line == 44)' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "a second occurrence with the same title is posted; the first is not reposted"
  else
    fail "a second occurrence of a posted finding was dropped (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M9. Titles that differ only in symbols are different findings.
  W="$(new_ws m9)"; P="$(new_pr m9)"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR bug src/a.py:10 'Use `<` not `<=`')"
  pr_round "$W" "$P"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR bug src/a.py:10 'Use `<` not `<=`')" \
                            "$(fnd B MAJOR bug src/a.py:30 'Use `<=` not `<`')"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '(.comments | length == 1) and (.comments[0].line == 30)' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "titles that differ only in punctuation do not collide"
  else
    fail "a finding was taken for another whose title differs only in symbols (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M10. finalize can change a finding's category between runs (a scanner reporting the same
  #      location and title wins the duplicate fold). The category is not part of the key.
  W="$(new_ws m10)"; P="$(new_pr m10)"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR security src/cfg.py:3 'Hardcoded API key')"
  pr_round "$W" "$P"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR secrets src/cfg.py:3 'Hardcoded API key')"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && [ ! -s "$ROUND_PAY" ]; then
    pass "a finding whose category changed between runs is not reposted"
  else
    fail "a category change reposted a finding (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M11. The previous version's slugged marker (fp:<category>~<path>~<title>) still counts.
  W="$(new_ws m11)"; P="$(new_pr m11)"
  write_three_findings "$W"
  printf '%s\n' '[{"path": "src/auth.py", "user": {"login": "review-bot"}, "body": "**BLOCKER / authz** Tenant id is not part of the cache key\n\n<!-- code-review-core:fp:authz~src/auth.py~tenant-id-is-not-part-of-the-cache-key -->"}]' > "$P/comments.json"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '((.comments // []) | length == 0) and (.body | contains("SEM-002"))' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "the previous version's fp:<category>~<path>~<title> marker is honoured"
  else
    fail "a finding posted under the previous marker form was reposted (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M12. A first-version id marker counts only for the entry it sits in, and only when that entry's
  #      title and location both match: a shorter title contained in the old one is a new finding.
  W="$(new_ws m12)"; P="$(new_pr m12)"
  vdoc "$W" REQUEST_CHANGES "$(fnd VALIDATED-MAJOR-1 MAJOR errors src/api/handler.py:40 'Missing null check')"
  printf '%s\n' '[{"id": 1, "state": "CHANGES_REQUESTED", "user": {"login": "review-bot"}, "body": "## Code review\n\n- **MAJOR** / errors / `src/parser.py:12`  \n  Missing null check in parser  \n  <!-- code-review-core:finding:VALIDATED-MAJOR-1 -->"}]' > "$P/reviews.json"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '.comments[0].path == "src/api/handler.py"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "a legacy id marker does not swallow a different finding whose title it merely contains"
  else
    fail "a legacy id marker hid a new finding (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # M13. Over the size limit: first compacted (evidence dropped), and when that is still too big, cut
  #      at a whole entry, so every finding shown carries its marker.
  W="$(new_ws m13)"
  jq -n --arg e "$(head -c 1900 /dev/zero | tr '\0' 'x')" '{agent: "a", category: "VALIDATED",
    verdict: "APPROVE", blocking_floor: "MINOR", blocking_reason_ids: [],
    findings: [range(0; 40) | {id: "F\(.)", severity: "MINOR", category: "c", location: "src/f\(.).py:1",
      title: "Finding \(.)", evidence: $e, recommendation: "r", in_diff: false, ux_impact: false, confidence: "HIGH"}]}' \
    > "$W/.code-review/VALIDATED.json"
  b1="$(dry_payload "$W" | jq -r '.body')"
  W2="$(new_ws m13-cut)"
  jq -n '{agent: "a", category: "VALIDATED", verdict: "APPROVE", blocking_floor: "MINOR", blocking_reason_ids: [],
    findings: [range(0; 400) | {id: "F\(.)", severity: "MINOR", category: "c", location: "src/f\(.).py:1",
      title: ("Finding \(.) " + ("t" * 150)), evidence: "e", recommendation: "r", in_diff: false, ux_impact: false, confidence: "HIGH"}]}' \
    > "$W2/.code-review/VALIDATED.json"
  b2="$(dry_payload "$W2" | jq -r '.body')"
  n_entries="$(printf '%s\n' "$b2" | grep -c '^- \*\*MINOR\*\* / ')"
  n_marks="$(printf '%s\n' "$b2" | grep -c '<!-- code-review-core:fp2:')"
  if [ "${#b1}" -le 65536 ] && [ "$(printf '%s\n' "$b1" | grep -c '<!-- code-review-core:fp2:')" -eq 40 ] \
     && ! printf '%s' "$b1" | grep -q 'Evidence:' \
     && [ "${#b2}" -le 65536 ] && printf '%s' "$b2" | grep -q 'Body truncated' \
     && [ "$n_entries" -gt 0 ] && [ "$n_entries" -eq "$n_marks" ]; then
    pass "an oversized body is compacted, then cut at a whole entry (${#b1} and ${#b2} chars, $n_marks entries)"
  else
    fail "the size limit was not handled (compact ${#b1} chars; cut ${#b2} chars, $n_entries entries, $n_marks markers)"
  fi

  # M14. The success line counts the findings that landed, not the ones that were routed.
  P="$(new_pr m14)"
  pr_round "$W2" "$P"
  landed="$(jq -r '.body' "$ROUND_PAY" | grep -c '<!-- code-review-core:fp2:')"
  if [ "$ROUND_RC" -eq 0 ] && printf '%s' "$ROUND_OUT" | grep -q "0 inline, $landed in body" \
     && printf '%s' "$ROUND_OUT" | grep -q "$((400 - landed)) of 400 body finding(s) did not fit"; then
    pass "a truncated post reports the $landed findings that landed and says to re-run for the rest"
  else
    fail "a truncated post misreported what landed ($landed markers): $ROUND_OUT"
  fi

  # V1. Another account's comment that quotes a fingerprint marker does not count as posted.
  W="$(new_ws v1)"; P="$(new_pr v1)"
  vdoc "$W" REQUEST_CHANGES "$(fnd A MAJOR x src/a.py:3 'Bug A')"
  printf '%s\n' '[{"path": "src/a.py", "user": {"login": "pr-author"}, "body": "LGTM <!-- code-review-core:fp2:src%2Fa.py:bug%20a -->"}]' > "$P/comments.json"
  pr_round "$W" "$P"
  if [ "$ROUND_RC" -eq 0 ] && jq -e '.comments[0].path == "src/a.py"' "$ROUND_PAY" >/dev/null 2>&1; then
    pass "a marker in another account's comment does not suppress a finding"
  else
    fail "another account's comment suppressed a finding (rc=$ROUND_RC): $ROUND_OUT"
  fi

  # V2. A finding that was fixed and later returns (same title, same file, another line) is posted
  #     again; the run that saw it gone records the new open set; an unchanged re-run posts nothing.
  W="$(new_ws v2)"; P="$(new_pr v2)"
  vdoc "$W" APPROVE "$(fnd A NIT shell deploy.sh:10 'Magic number')"
  pr_round "$W" "$P"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"; rc2=$ROUND_RC; open2="$(jq -r '.body' "$ROUND_PAY" 2>/dev/null | sed -n 4p)"
  vdoc "$W" APPROVE "$(fnd A NIT shell deploy.sh:44 'Magic number')"
  pr_round "$W" "$P"; rc3=$ROUND_RC; line3="$(jq -r '.comments[0].line' "$ROUND_PAY" 2>/dev/null)"
  pr_round "$W" "$P"
  if [ "$rc2" -eq 0 ] && [ "$open2" = "<!-- code-review-core:active: -->" ] && [ "$rc3" -eq 0 ] \
     && [ "$line3" = "44" ] && [ "$ROUND_RC" -eq 0 ] && [ ! -s "$ROUND_PAY" ]; then
    pass "a fixed finding that returns is posted again, and an unchanged re-run posts nothing"
  else
    fail "the open set was not honoured (rc=$rc2/$rc3/$ROUND_RC, open='$open2', line=$line3): $ROUND_OUT"
  fi

  # V3. A PR posted before the open set existed: an unchanged re-run posts nothing, and a fixed
  #     finding makes a review that records the open set.
  W="$(new_ws v3)"; P="$(new_pr v3)"
  printf '%s\n' '[{"path": "src/a.py", "user": {"login": "review-bot"}, "pull_request_review_id": 1, "body": "x <!-- code-review-core:fp2:src%2Fa.py:bug%20a -->"}]' > "$P/comments.json"
  printf '%s\n' '[{"id": 1, "state": "COMMENTED", "user": {"login": "review-bot"}, "body": "## Code review\n\n<!-- code-review-core:verdict:APPROVE -->\n"}]' > "$P/reviews.json"
  vdoc "$W" APPROVE "$(fnd A NIT x src/a.py:3 'Bug A')"
  pr_round "$W" "$P"; rc1=$ROUND_RC; sent1="$(wc -c < "$ROUND_PAY")"
  vdoc "$W" APPROVE
  pr_round "$W" "$P"
  if [ "$rc1" -eq 0 ] && [ "$sent1" -eq 0 ] && [ "$ROUND_RC" -eq 0 ] \
     && jq -r '.body' "$ROUND_PAY" | grep -q '^<!-- code-review-core:active: -->$'; then
    pass "a PR without an open set is not reposted, and records one once a finding closes"
  else
    fail "a PR without an open set was mishandled (rc1=$rc1 sent1=$sent1 rc=$ROUND_RC): $ROUND_OUT"
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
