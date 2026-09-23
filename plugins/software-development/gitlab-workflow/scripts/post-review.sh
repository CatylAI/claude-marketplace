#!/usr/bin/env bash
# post-review.sh - post a finished code-review-core review to a GitLab merge request.
#
#   scripts/post-review.sh [--mr <iid>] [--project <group/project>] [--artifacts <dir>]
#                          [--dry-run] [--no-approve]
#
# Reads <artifacts>/VALIDATED.json (the agent contract code-review-core's validator writes last),
# routes each finding to an inline discussion on the MR diff or to the MR-level note body, and posts
# the result. It decides nothing about the code: no severity is changed, no verdict is computed when
# the document supplies one, and no finding is dropped.
#
# REFUSALS ARE THE POINT. A missing or unparseable VALIDATED.json means the review did not finish,
# and a clean review posted over an unfinished run turns "we do not know" into a green pipeline that
# a human will trust. Every such path exits non-zero and posts nothing.
#
# WHAT IS DIFFERENT FROM THE GITHUB ADAPTER, AND WHY
#
#   1. POSITION. GitHub anchors an inline comment with a path and a line. GitLab will not: a diff
#      note needs a `position` object carrying the MR's three diff SHAs (base_sha, start_sha,
#      head_sha) alongside new_path/old_path/new_line. Those SHAs come from the MR's `diff_refs`,
#      which is one GET away and is NOT derivable from the checkout. No diff_refs, no inline notes -
#      and this script refuses rather than silently posting every finding unanchored.
#
#   2. NO ATOMIC REVIEW. GitHub has one endpoint that takes a body plus every inline comment and
#      lands them together. GitLab has no such call. The closest thing is draft notes: POST each
#      inline note to /draft_notes (invisible until published), verify EVERY one of them, then
#      /draft_notes/bulk_publish once. If any draft fails to verify, the drafts this run created are
#      deleted and nothing is published - so a non-zero exit still means the MR is untouched.
#
#   3. A DRAFT NOTE CAN BE ACCEPTED AND STILL NOT BE INLINE. GitLab answers a POST whose `position`
#      it cannot resolve against the diff with 201 and `position: null`, and renders it as an
#      ordinary comment. Exit code and HTTP status both look fine. So each note is verified twice:
#      `.id` must be an integer (catches an error body glab exited 0 on) and `.position` must be
#      non-null (catches the accepted-but-unanchored case). An unanchored note is the wrong
#      artifact, not a degraded one.
#
#   4. VERDICT. GitLab has no portable API equivalent of GitHub's REQUEST_CHANGES review event, so
#      only APPROVE has an action behind it (POST /approve). REQUEST_CHANGES and INCOMPLETE are
#      carried in the summary note's body and the MR is left unapproved. See skills/review-transport.
#
# SAFETY. Findings are untrusted text - an agent reviewing a shell script routinely quotes command
# substitutions, backticks and semicolons. No value from the document is ever interpolated into a
# string the shell re-parses: jq carries every field into a JSON payload, the payload reaches glab
# through a file, and nothing here builds a command string or calls eval.
#
# Test seam: GLAB_BIN overrides the `glab` binary.
# Portable bash 3.2+ / zsh: no mapfile, no `declare -A`, no ${var^^}.
set -euo pipefail

GLAB="${GLAB_BIN:-glab}"
MARKER_NS="code-review-core:finding"

ARTIFACTS=".code-review"
MR_IID=""
PROJECT=""
DRY_RUN=0
APPROVE_ENABLED=1

fail() { # <exit-code> <message...>
  code="$1"; shift
  printf 'post-review: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
post-review.sh - post a finished code-review-core review to a GitLab merge request.

  --mr <iid>                 merge request IID (default: the MR for the current branch)
  --project <group/project>  project path (default: resolved from the checkout's origin remote)
  --artifacts <dir>          directory holding VALIDATED.json (default: .code-review)
  --dry-run                  print the routing plan and the exact payloads; make no glab call at all
  --no-approve               never call the approve endpoint, even on an APPROVE verdict
  -h, --help                 this text

Environment:
  CODE_REVIEW_BLOCKING_FLOOR   BLOCKER|MAJOR|MINOR|NIT, default MINOR. Decides which findings are
                               listed as blocking, and the review event when the document carries
                               no verdict of its own.
  GLAB_BIN                     path to the glab binary (default: glab).

Exit status: 0 posted (or nothing new to post). Non-zero means the merge request was left as it was,
with the reason on stderr - except exit 11 and above, which say exactly what did land.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mr)         [ $# -ge 2 ] || fail 2 "--mr needs an IID"; MR_IID="$2"; shift 2 ;;
    --project)    [ $# -ge 2 ] || fail 2 "--project needs <group/project>"; PROJECT="$2"; shift 2 ;;
    --artifacts)  [ $# -ge 2 ] || fail 2 "--artifacts needs a directory"; ARTIFACTS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-approve) APPROVE_ENABLED=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            fail 2 "unknown argument: $1 (try --help)" ;;
  esac
done

case "$MR_IID" in
  "") ;;
  *[!0-9]*) fail 2 "--mr must be a number, got: $MR_IID" ;;
esac

# --- jq is not optional -------------------------------------------------------------------------
# Parsing this document with sed would mean parsing attacker-influenced JSON with a line-oriented
# tool. Refusing is the only correct behaviour when jq is absent.
command -v jq >/dev/null 2>&1 || fail 3 \
  "jq is required and was not found on PATH. Install jq and re-run. Nothing was posted."

# --- the completion signal ----------------------------------------------------------------------
VALIDATED="$ARTIFACTS/VALIDATED.json"
[ -f "$VALIDATED" ] || fail 4 \
  "$VALIDATED does not exist, so the review did not finish. Run code-review-core's pipeline through its validator first. Nothing was posted."
jq empty "$VALIDATED" >/dev/null 2>&1 || fail 5 \
  "$VALIDATED is not parseable JSON, so the review did not finish cleanly. Nothing was posted."

# --- the blocking floor -------------------------------------------------------------------------
FLOOR="$(printf '%s' "${CODE_REVIEW_BLOCKING_FLOOR:-MINOR}" | tr '[:lower:]' '[:upper:]')"
case "$FLOOR" in
  BLOCKER|MAJOR|MINOR|NIT) ;;
  *) fail 6 "CODE_REVIEW_BLOCKING_FLOOR must be BLOCKER, MAJOR, MINOR or NIT; got: $FLOOR. Nothing was posted." ;;
esac

FINDING_COUNT="$(jq '(.findings // []) | length' "$VALIDATED" 2>/dev/null)" || fail 5 \
  "$VALIDATED has no readable .findings array. Nothing was posted."
case "$FINDING_COUNT" in
  ""|*[!0-9]*) fail 5 "$VALIDATED has no readable .findings array. Nothing was posted." ;;
esac
DOC_VERDICT="$(jq -r '.verdict // ""' "$VALIDATED" 2>/dev/null)" || DOC_VERDICT=""

if [ "$FINDING_COUNT" -eq 0 ] && [ -z "$DOC_VERDICT" ]; then
  fail 7 "$VALIDATED has zero findings AND no verdict - that is an empty result, not an approval. Nothing was posted."
fi

# --- scratch space --------------------------------------------------------------------------------
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/post-review.XXXXXX")"
cleanup() { [ -n "${TMPD:-}" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

# --- glab plumbing ----------------------------------------------------------------------------------
# GL_STATUS is the verbatim status line ("HTTP/1.1 201 Created") or empty when glab emitted none;
# the response body lands in $TMPD/body. `-i` is what makes the status available at all: without it
# a 4xx that glab exits 0 on is indistinguishable from a 2xx.
#
# stdout and stderr are combined deliberately - glab prints some status information to stderr, and
# splitting the streams here would discard the thing being verified.
GL_STATUS=""
GL_RC=0
gl_write() { # <method> <endpoint> [input-file]
  _method="$1"; _endpoint="$2"; _input="${3:-}"
  : > "$TMPD/raw"
  GL_RC=0
  if [ -n "$_input" ]; then
    "$GLAB" api --method "$_method" --header "Content-Type: application/json" \
      --input "$_input" -i "$_endpoint" > "$TMPD/raw" 2>&1 || GL_RC=$?
  else
    "$GLAB" api --method "$_method" -i "$_endpoint" > "$TMPD/raw" 2>&1 || GL_RC=$?
  fi
  # CR is removed before anything looks at the bytes: a JSON body escapes a real carriage return as
  # the two characters \r, so nothing in the payload can be damaged by dropping literal CRs, and the
  # header/body split stops depending on whether this awk understands \r in a pattern.
  tr -d '\r' < "$TMPD/raw" > "$TMPD/raw.nocr"
  GL_STATUS="$(sed -n 's|^\(HTTP/[0-9.]* [0-9][0-9][0-9]\).*|\1|p' "$TMPD/raw.nocr" | head -1)"
  if [ -n "$GL_STATUS" ]; then
    awk 'seen { print } /^$/ { seen = 1 }' "$TMPD/raw.nocr" > "$TMPD/body"
  else
    cp "$TMPD/raw.nocr" "$TMPD/body"
  fi
  return 0
}

gl_status_is_2xx() {
  case "$GL_STATUS" in
    HTTP/*\ 2??) return 0 ;;
    *) return 1 ;;
  esac
}

# GitLab bodies carry raw control bytes often enough that jq dies at parse time on real MR titles.
# Everything read back here is stripped before it reaches jq.
strip_ctrl() { tr -d '\001-\010\013\014\016-\037'; }

# --- resolve the merge request ----------------------------------------------------------------------
BASE_SHA="(resolved from the MR's diff_refs at post time)"
START_SHA="$BASE_SHA"
HEAD_SHA="$BASE_SHA"
POSTED_IDS='[]'
MR_BASE=""

if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$GLAB" >/dev/null 2>&1 || fail 8 \
    "the glab CLI is required to post and was not found on PATH. Re-run with --dry-run to see the plan. Nothing was posted."

  # glab api has no --repo: the project is part of the path. `:id` is glab's own placeholder for the
  # project the checkout's origin remote points at; an explicit --project is URL-encoded instead.
  if [ -n "$PROJECT" ]; then
    PROJECT_REF="$(printf '%s' "$PROJECT" | sed 's|/|%2F|g')"
  else
    PROJECT_REF=":id"
  fi

  if [ -z "$MR_IID" ]; then
    MR_IID="$("$GLAB" mr view --output json 2>/dev/null | strip_ctrl | jq -r '.iid // empty' 2>/dev/null || true)"
    [ -n "$MR_IID" ] || fail 8 \
      "could not resolve a merge request for the current branch. Pass --mr <iid>. Nothing was posted."
  fi
  case "$MR_IID" in
    *[!0-9]*) fail 8 "resolved a non-numeric merge request IID: $MR_IID. Pass --mr <iid>. Nothing was posted." ;;
  esac

  MR_BASE="projects/$PROJECT_REF/merge_requests/$MR_IID"

  "$GLAB" api "$MR_BASE" 2>/dev/null | strip_ctrl > "$TMPD/mr.json" || true
  jq empty "$TMPD/mr.json" >/dev/null 2>&1 || fail 8 \
    "could not read $MR_BASE - glab returned nothing parseable. Check 'glab auth status' and the project path. Nothing was posted."

  BASE_SHA="$(jq -r '.diff_refs.base_sha  // ""' "$TMPD/mr.json")"
  START_SHA="$(jq -r '.diff_refs.start_sha // ""' "$TMPD/mr.json")"
  HEAD_SHA="$(jq -r '.diff_refs.head_sha  // ""' "$TMPD/mr.json")"

  # An inline note needs all three. Posting without them would mean every finding silently landing
  # as an unanchored comment, which is the failure this whole script is shaped around.
  if [ -z "$BASE_SHA" ] || [ -z "$START_SHA" ] || [ -z "$HEAD_SHA" ]; then
    fail 8 "the merge request carries no usable diff_refs (base_sha/start_sha/head_sha), so no finding can be anchored to a line. Nothing was posted."
  fi

  # --- what is already on the merge request ---------------------------------------------------------
  # The marker is grepped out of the raw response rather than parsed: it contains no character JSON
  # escapes, and a control byte in an unrelated note's body must not be able to make a re-run
  # duplicate the whole review. Draft notes are read too - a previous run may have created drafts
  # that never published. An older GitLab without the draft_notes collection just yields nothing.
  EXISTING="$( { "$GLAB" api "$MR_BASE/notes" --paginate 2>/dev/null || true
                 "$GLAB" api "$MR_BASE/draft_notes" --paginate 2>/dev/null || true; } | strip_ctrl )"
  MARKED="$(printf '%s\n' "$EXISTING" | grep -o "$MARKER_NS:[A-Za-z0-9._:/-]*" || true)"
  POSTED_IDS="$(printf '%s\n' "$MARKED" \
    | sed "s/^$MARKER_NS://" \
    | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
fi

# --- routing, body and payloads, computed entirely inside jq ----------------------------------------
JQ_PROG="$(cat <<'JQPROG'
def rank: {"BLOCKER":4,"MAJOR":3,"MINOR":2,"NIT":1}[. // ""] // 0;
def sev: (.severity // "MINOR");
def mark($id): "<!-- " + $ns + ":" + $id + " -->";
def oneline: (. // "") | tostring | gsub("[\n\r]"; " ");
def parseloc:
  ((((.location // "") | capture("^(?<p>[^:\\s]+)(?::|\\s+(?:[Ll]ine\\s+)?)(?<n>[0-9]+)"))?) // null);
def bodyentry:
  "- **\(sev)** / \(.category // "review") / `\((.location // "n/a") | oneline)`  \n"
  + "  \((.title // "(untitled)") | oneline)  \n"
  + (if ((.evidence // "") | length) > 0 then "  Evidence: \(.evidence | oneline)  \n" else "" end)
  + (if ((.recommendation // "") | length) > 0 then "  Recommendation: \(.recommendation | oneline)  \n" else "" end)
  + "  _confidence: \(.confidence // "?"), in_diff: \(.in_diff), ux_impact: \(.ux_impact)_  \n"
  + "  " + mark(.id // "unknown");
def inlinebody:
  "**\(sev) / \(.category // "review")** \((.title // "(untitled)") | oneline)\n\n"
  + (if ((.evidence // "") | length) > 0 then "\(.evidence)\n\n" else "" end)
  + (if ((.recommendation // "") | length) > 0 then "**Recommendation:** \(.recommendation)\n\n" else "" end)
  + "_confidence: \(.confidence // "?"), finding `\(.id // "unknown")`_\n"
  + mark(.id // "unknown");

($floor | ascii_upcase) as $fl
| ($fl | rank) as $flr
| (.verdict // "") as $verdict
| ((.findings // []) | map(select(type == "object"))) as $all
| (if   $verdict == "REQUEST_CHANGES" then "REQUEST_CHANGES"
   elif $verdict == "APPROVE"         then "APPROVE"
   elif $verdict == "INCOMPLETE"      then "COMMENT"
   elif ($all | map(select((.in_diff == true) and ((sev | rank) >= $flr))) | length) > 0
        then "REQUEST_CHANGES"
   else "COMMENT" end) as $event
| ("verdict-" + (if $verdict == "" then "DERIVED-" + $event else $verdict end)) as $vmark
| ($all | map(. + {_loc: parseloc})) as $ann
| ($ann | map(select(. as $f | ($posted | index($f.id // " ")) == null))) as $new
| ($ann | map(select(. as $f | ($posted | index($f.id // " ")) != null))) as $dup
| ($new | map(select((.in_diff == true) and (._loc != null)))) as $inline
| ($new | map(select((.in_diff != true) or  (._loc == null)))) as $bodyf
| ((($all | length) == 0) and (($posted | index($vmark)) == null)) as $vpending
| ([ "## Code review",
     "",
     (if $verdict == ""
      then "No `verdict` in the document - event derived from `CODE_REVIEW_BLOCKING_FLOOR=\($fl)`: `\($event)`."
      else "Verdict: **\($verdict)** - review event `\($event)`." end),
     "",
     "\($all | length) finding(s) in `VALIDATED.json` - "
       + ([ "BLOCKER", "MAJOR", "MINOR", "NIT" ]
          | map(. as $s | "\($all | map(select((.severity // "MINOR") == $s)) | length) \($s)")
          | join(", ")) + ".",
     "" ]
   + (if $verdict == "INCOMPLETE" then
        [ "**This review is incomplete.** The validator did not finish tracing every finding, so it "
          + "is posted as a comment - not an approval and not a rejection. This merge request has "
          + "not been approved by it."
          + (if ((.blocking_reason_ids // []) | length) > 0
             then " Unresolved: " + ((.blocking_reason_ids // []) | map("`" + tostring + "`") | join(", ")) + "."
             else "" end),
          "" ]
      else [] end)
   + (if $event == "REQUEST_CHANGES" then
        [ "**Changes are requested.** GitLab has no API-level \"request changes\" review event, so "
          + "this is the statement of it: the merge request is deliberately left unapproved.", "" ]
      else [] end)
   + (($all | map(select((.in_diff == true) and ((sev | rank) >= $flr)))) as $blk
      | if ($blk | length) > 0 then
          [ "### Blocking - at or above `\($fl)`, introduced by this diff", "" ]
          + ($blk | map("- **\(sev)** `\((.location // "n/a") | oneline)` \((.title // "(untitled)") | oneline)"))
          + [ "" ]
        else [] end)
   + (if ($inline | length) > 0 then
        [ "\($inline | length) finding(s) are attached inline to the lines they cite.", "" ]
      else [] end)
   + (($bodyf | map(select(.in_diff != true))) as $pre
      | if ($pre | length) > 0 then
          [ "### Pre-existing - not introduced by this diff", "",
            "These keep their severity; being out of scope is what stops them blocking. A GitLab diff note can only anchor to a line inside this merge request's diff, so they are listed here.", "" ]
          + ($pre | map(bodyentry)) + [ "" ]
        else [] end)
   + (($bodyf | map(select(.in_diff == true))) as $unp
      | if ($unp | length) > 0 then
          [ "### Could not be placed on a line", "",
            "These cite this diff, but their `location` did not parse into a path and a line. Listed here rather than dropped.", "" ]
          + ($unp | map(bodyentry)) + [ "" ]
        else [] end)
   + (if ($dup | length) > 0 then
        [ "_\($dup | length) finding(s) already present on this merge request were skipped._", "" ]
      else [] end)
   + (if $vpending then [ mark($vmark) ] else [] end)
   | join("\n")) as $body
| (($inline | map("inline  \(._loc.p):\(._loc.n)  [\(sev)] \(.id // "?") \((.title // "") | oneline)"))
   + ($bodyf | map("body    [\(sev)] \(.id // "?") \((.title // "") | oneline)  (reason: "
                   + (if .in_diff != true then "in_diff=false" else "location did not parse" end) + ")"))
   + ($dup   | map("skip    \(.id // "?") already posted"))
   + (if $vpending then [ "body    verdict-only review (the document has no findings)" ] else [] end)
  ) as $plan
| { event: $event,
    verdict: $verdict,
    floor: $fl,
    plan: $plan,
    new_count: (($new | length) + (if $vpending then 1 else 0 end)),
    dup_count: ($dup | length),
    inline_count: ($inline | length),
    body_count: ($bodyf | length),
    payload: {
      summary: { body: $body },
      inline: ($inline | map({
        finding_id: (.id // "unknown"),
        draft: {
          note: inlinebody,
          position: {
            base_sha:      $base_sha,
            start_sha:     $start_sha,
            head_sha:      $head_sha,
            position_type: "text",
            new_path:      ._loc.p,
            old_path:      ._loc.p,
            new_line:      (._loc.n | tonumber)
          }
        }
      }))
    } }
JQPROG
)"

RESULT="$(jq --argjson posted "$POSTED_IDS" --arg floor "$FLOOR" --arg ns "$MARKER_NS" \
             --arg base_sha "$BASE_SHA" --arg start_sha "$START_SHA" --arg head_sha "$HEAD_SHA" \
             "$JQ_PROG" "$VALIDATED")" || fail 5 \
  "could not route the findings in $VALIDATED - the document does not match the agent contract. Nothing was posted."
[ -n "$RESULT" ] || fail 5 "routing produced no output for $VALIDATED. Nothing was posted."

printf '%s' "$RESULT" > "$TMPD/result.json"

EVENT="$(jq -r '.event' "$TMPD/result.json")"
NEW_COUNT="$(jq -r '.new_count' "$TMPD/result.json")"
DUP_COUNT="$(jq -r '.dup_count' "$TMPD/result.json")"
INLINE_COUNT="$(jq -r '.inline_count' "$TMPD/result.json")"
BODY_COUNT="$(jq -r '.body_count' "$TMPD/result.json")"
PLAN="$(jq -r '.plan[]?' "$TMPD/result.json")"

# An INCOMPLETE verdict must never leave this script as an approval. Asserted rather than assumed:
# the mapping above is the only place it is decided, and this is the check that it stayed decided.
if [ "$DOC_VERDICT" = "INCOMPLETE" ] && [ "$EVENT" = "APPROVE" ]; then
  fail 9 "refusing to post an INCOMPLETE review as an approval. Nothing was posted."
fi

WILL_APPROVE=0
if [ "$EVENT" = "APPROVE" ] && [ "$APPROVE_ENABLED" -eq 1 ]; then WILL_APPROVE=1; fi

# --- dry run: no glab call of any kind ---------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'post-review: DRY RUN - no GitLab API call will be made\n'
  printf '  project:        %s\n' "${PROJECT:-(resolved from origin at post time)}"
  printf '  merge request:  %s\n' "${MR_IID:-(the MR for the current branch)}"
  printf '  artifacts:      %s\n' "$VALIDATED"
  printf '  blocking floor: %s\n' "$FLOOR"
  printf '  verdict:        %s\n' "${DOC_VERDICT:-(absent, derived)}"
  printf '  review event:   %s\n' "$EVENT"
  printf '  approve call:   %s\n' "$([ "$WILL_APPROVE" -eq 1 ] && echo yes || echo no)"
  printf '  routing:        %s inline, %s in body, %s skipped\n' "$INLINE_COUNT" "$BODY_COUNT" "$DUP_COUNT"
  printf '\nplan:\n'
  if [ -n "$PLAN" ]; then printf '%s\n' "$PLAN" | sed 's/^/  /'; else printf '  (nothing to post)\n'; fi
  printf '\npayload:\n'
  jq '.payload' "$TMPD/result.json"
  exit 0
fi

if [ "$NEW_COUNT" -eq 0 ]; then
  printf 'post-review: every finding is already on %s!%s - nothing new to post (%s skipped).\n' \
    "${PROJECT:-<current project>}" "$MR_IID" "$DUP_COUNT"
  exit 0
fi

# --- inline notes, as unpublished drafts --------------------------------------------------------------
# Drafts first, every one verified, publish once. A note that fails verification takes the whole run
# down and the drafts this run created are deleted, so the merge request is left as it was.
: > "$TMPD/created.txt"

discard_drafts() {
  while IFS= read -r _did; do
    [ -n "$_did" ] || continue
    gl_write DELETE "$MR_BASE/draft_notes/$_did" || true
  done < "$TMPD/created.txt"
}

I=0
while [ "$I" -lt "$INLINE_COUNT" ]; do
  jq --argjson i "$I" '.payload.inline[$i].draft' "$TMPD/result.json" > "$TMPD/note-$I.json"
  FID="$(jq -r --argjson i "$I" '.payload.inline[$i].finding_id' "$TMPD/result.json")"

  gl_write POST "$MR_BASE/draft_notes" "$TMPD/note-$I.json"
  BODY_CLEAN="$(strip_ctrl < "$TMPD/body")"

  NOTE_ID="$(printf '%s' "$BODY_CLEAN" | jq -r 'if type == "object" and (.id | type) == "number" then .id else "" end' 2>/dev/null || true)"
  HAS_POS="$(printf '%s' "$BODY_CLEAN" | jq -r 'if type == "object" and has("position") and .position != null then "yes" else "no" end' 2>/dev/null || true)"

  if [ -z "$GL_STATUS" ]; then
    printf 'post-review: draft note for %s: glab exited %s and emitted no HTTP status line, so the response cannot be trusted.\n' "$FID" "$GL_RC" >&2
    discard_drafts
    fail 10 "could not verify the draft note for $FID. Nothing was published; the drafts this run created were deleted."
  fi
  if [ -z "$NOTE_ID" ]; then
    printf 'post-review: draft note for %s rejected (%s): %s\n' "$FID" "$GL_STATUS" "$(printf '%s' "$BODY_CLEAN" | head -c 500)" >&2
    discard_drafts
    fail 10 "GitLab did not return a note id for $FID. Nothing was published; the drafts this run created were deleted."
  fi
  printf '%s\n' "$NOTE_ID" >> "$TMPD/created.txt"
  if [ "$HAS_POS" != "yes" ]; then
    printf 'post-review: draft note for %s came back with position: null - GitLab accepted it but could not anchor it to the diff.\n' "$FID" >&2
    discard_drafts
    fail 10 "the position for $FID did not resolve against the merge request diff. An unanchored note is the wrong artifact, not a degraded one, so nothing was published."
  fi
  I=$((I + 1))
done

PUBLISHED=0
if [ "$INLINE_COUNT" -gt 0 ]; then
  gl_write POST "$MR_BASE/draft_notes/bulk_publish"
  if gl_status_is_2xx; then
    PUBLISHED=1
  else
    printf 'post-review: bulk_publish returned %s: %s\n' "${GL_STATUS:-<no status>}" \
      "$(strip_ctrl < "$TMPD/body" | head -c 500)" >&2
    discard_drafts
    fail 11 "every verified note was left as an unpublished draft and then deleted. Nothing is visible on the merge request."
  fi
fi

# --- the summary note ---------------------------------------------------------------------------------
# Posted after the inline notes, never before: a summary that claims N inline annotations while the
# annotations failed is a worse artifact than no summary.
jq '.payload.summary' "$TMPD/result.json" > "$TMPD/summary.json"
gl_write POST "$MR_BASE/notes" "$TMPD/summary.json"
SUMMARY_ID="$(strip_ctrl < "$TMPD/body" | jq -r 'if type == "object" and (.id | type) == "number" then .id else "" end' 2>/dev/null || true)"
if [ -z "$SUMMARY_ID" ]; then
  printf 'post-review: the summary note was rejected (%s): %s\n' "${GL_STATUS:-<no status>}" \
    "$(strip_ctrl < "$TMPD/body" | head -c 500)" >&2
  fail 12 "the summary note did not post. $INLINE_COUNT inline note(s) ARE published on the merge request; re-running will skip them and retry the summary."
fi

# --- the approval -------------------------------------------------------------------------------------
# Only APPROVE has an action behind it. REQUEST_CHANGES and INCOMPLETE leave the MR unapproved and
# say so in the body, which is the whole statement GitLab's API can carry.
if [ "$WILL_APPROVE" -eq 1 ]; then
  gl_write POST "$MR_BASE/approve"
  if ! gl_status_is_2xx; then
    printf 'post-review: the approve call returned %s: %s\n' "${GL_STATUS:-<no status>}" \
      "$(strip_ctrl < "$TMPD/body" | head -c 500)" >&2
    fail 13 "the review posted but the approval did not. The merge request carries the review and is NOT approved."
  fi
fi

printf 'post-review: posted %s to merge request !%s - %s inline (published: %s), %s in body, %s skipped as already present%s.\n' \
  "$EVENT" "$MR_IID" "$INLINE_COUNT" \
  "$([ "$PUBLISHED" -eq 1 ] && echo yes || echo "n/a")" \
  "$BODY_COUNT" "$DUP_COUNT" \
  "$([ "$WILL_APPROVE" -eq 1 ] && echo ", approved" || echo "")"
