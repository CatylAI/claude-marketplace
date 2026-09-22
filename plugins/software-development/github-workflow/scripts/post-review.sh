#!/usr/bin/env bash
# post-review.sh - post a finished code-review-core review to a GitHub pull request.
#
#   scripts/post-review.sh [--pr <n>] [--repo <owner>/<repo>] [--artifacts <dir>] [--dry-run]
#
# Reads <artifacts>/VALIDATED.json (the agent contract code-review-core's validator writes last),
# routes each finding to an inline review comment or the review body, and submits ONE review whose
# event follows the document's verdict. It decides nothing about the code: no severity is changed,
# no verdict is computed when the document supplies one, and no finding is dropped.
#
# REFUSALS ARE THE POINT. A missing or unparseable VALIDATED.json means the review did not finish,
# and a clean review posted over an unfinished run turns "we do not know" into a green check that a
# human will trust. Every such path exits non-zero and posts nothing.
#
# SAFETY. Findings are untrusted text - an agent reviewing a shell script routinely quotes command
# substitutions, backticks and semicolons. No value from the document is ever interpolated into a
# string the shell re-parses: jq carries every field into a JSON payload, the payload reaches gh
# through a file, and nothing here builds a command string or calls eval.
#
# Portable bash 3.2+ / zsh: no mapfile, no `declare -A`, no ${var^^}.
set -euo pipefail

ARTIFACTS=".code-review"
PR_NUMBER=""
REPO=""
DRY_RUN=0

fail() { # <exit-code> <message...>
  code="$1"; shift
  printf 'post-review: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
post-review.sh - post a finished code-review-core review to a GitHub pull request.

  --pr <number>           pull request to post to (default: the PR for the current branch)
  --repo <owner>/<repo>   repository (default: resolved from the checkout's origin remote)
  --artifacts <dir>       directory holding VALIDATED.json (default: .code-review)
  --dry-run               print the routing plan and the exact payload; make no gh call at all
  -h, --help              this text

Environment:
  CODE_REVIEW_BLOCKING_FLOOR   BLOCKER|MAJOR|MINOR|NIT, default MINOR. Decides which findings are
                               listed as blocking, and the review event when the document carries
                               no verdict of its own.

Exit status: 0 posted (or nothing new to post). Non-zero means NOTHING was posted, with the reason
on stderr.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)         [ $# -ge 2 ] || fail 2 "--pr needs a number"; PR_NUMBER="$2"; shift 2 ;;
    --repo)       [ $# -ge 2 ] || fail 2 "--repo needs <owner>/<repo>"; REPO="$2"; shift 2 ;;
    --artifacts)  [ $# -ge 2 ] || fail 2 "--artifacts needs a directory"; ARTIFACTS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            fail 2 "unknown argument: $1 (try --help)" ;;
  esac
done

case "$PR_NUMBER" in
  "") ;;
  *[!0-9]*) fail 2 "--pr must be a number, got: $PR_NUMBER" ;;
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

# --- what is already on the pull request --------------------------------------------------------
POSTED_IDS='[]'
if [ "$DRY_RUN" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || fail 8 \
    "the gh CLI is required to post and was not found on PATH. Re-run with --dry-run to see the plan. Nothing was posted."

  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || fail 8 \
      "could not resolve the repository. Pass --repo <owner>/<repo>. Nothing was posted."
  fi
  if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER="$(gh pr view --json number --jq '.number')" || fail 8 \
      "could not resolve a pull request for the current branch. Pass --pr <number>. Nothing was posted."
  fi
  { [ -n "$REPO" ] && [ -n "$PR_NUMBER" ]; } || fail 8 "empty repository or pull request number. Nothing was posted."

  EXISTING="$( { gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate --jq '.[].body'
                 gh api "repos/$REPO/pulls/$PR_NUMBER/reviews"  --paginate --jq '.[].body'; } 2>/dev/null || true )"
  MARKED="$(printf '%s\n' "$EXISTING" | grep -o 'code-review-core:finding:[A-Za-z0-9._:/-]*' || true)"
  POSTED_IDS="$(printf '%s\n' "$MARKED" \
    | sed 's/^code-review-core:finding://' \
    | jq -R -s 'split("\n") | map(select(length > 0)) | unique')"
fi

# --- routing, body and payload, computed entirely inside jq ---------------------------------------
JQ_PROG="$(cat <<'JQPROG'
def rank: {"BLOCKER":4,"MAJOR":3,"MINOR":2,"NIT":1}[. // ""] // 0;
def sev: (.severity // "MINOR");
def mark($id): "<!-- code-review-core:finding:" + $id + " -->";
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
          + "is posted as a comment - not an approval and not a rejection."
          + (if ((.blocking_reason_ids // []) | length) > 0
             then " Unresolved: " + ((.blocking_reason_ids // []) | map("`" + tostring + "`") | join(", ")) + "."
             else "" end),
          "" ]
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
            "These keep their severity; being out of scope is what stops them blocking. GitHub rejects an inline comment on a line this diff did not touch, so they are listed here.", "" ]
          + ($pre | map(bodyentry)) + [ "" ]
        else [] end)
   + (($bodyf | map(select(.in_diff == true))) as $unp
      | if ($unp | length) > 0 then
          [ "### Could not be placed on a line", "",
            "These cite this diff, but their `location` did not parse into a path and a line. Listed here rather than dropped.", "" ]
          + ($unp | map(bodyentry)) + [ "" ]
        else [] end)
   + (if ($dup | length) > 0 then
        [ "_\($dup | length) finding(s) already present on this pull request were skipped._", "" ]
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
    payload: ({ body: $body, event: $event }
              + (if ($inline | length) > 0
                 then { comments: ($inline | map({ path: ._loc.p,
                                                   line: (._loc.n | tonumber),
                                                   side: "RIGHT",
                                                   body: inlinebody })) }
                 else {} end)) }
JQPROG
)"

RESULT="$(jq --argjson posted "$POSTED_IDS" --arg floor "$FLOOR" "$JQ_PROG" "$VALIDATED")" || fail 5 \
  "could not route the findings in $VALIDATED - the document does not match the agent contract. Nothing was posted."
[ -n "$RESULT" ] || fail 5 "routing produced no output for $VALIDATED. Nothing was posted."

EVENT="$(printf '%s' "$RESULT" | jq -r '.event')"
NEW_COUNT="$(printf '%s' "$RESULT" | jq -r '.new_count')"
DUP_COUNT="$(printf '%s' "$RESULT" | jq -r '.dup_count')"
INLINE_COUNT="$(printf '%s' "$RESULT" | jq -r '.inline_count')"
BODY_COUNT="$(printf '%s' "$RESULT" | jq -r '.body_count')"
PLAN="$(printf '%s' "$RESULT" | jq -r '.plan[]?')"

# An INCOMPLETE verdict must never leave this script as an approval. Asserted rather than assumed:
# the mapping above is the only place it is decided, and this is the check that it stayed decided.
if [ "$DOC_VERDICT" = "INCOMPLETE" ] && [ "$EVENT" = "APPROVE" ]; then
  fail 9 "refusing to post an INCOMPLETE review as an approval. Nothing was posted."
fi

# --- dry run: no gh call of any kind --------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'post-review: DRY RUN - no GitHub API call will be made\n'
  printf '  repository:     %s\n' "${REPO:-(resolved from origin at post time)}"
  printf '  pull request:   %s\n' "${PR_NUMBER:-(the PR for the current branch)}"
  printf '  artifacts:      %s\n' "$VALIDATED"
  printf '  blocking floor: %s\n' "$FLOOR"
  printf '  verdict:        %s\n' "${DOC_VERDICT:-(absent, derived)}"
  printf '  review event:   %s\n' "$EVENT"
  printf '  routing:        %s inline, %s in body, %s skipped\n' "$INLINE_COUNT" "$BODY_COUNT" "$DUP_COUNT"
  printf '\nplan:\n'
  if [ -n "$PLAN" ]; then printf '%s\n' "$PLAN" | sed 's/^/  /'; else printf '  (nothing to post)\n'; fi
  printf '\npayload:\n'
  printf '%s' "$RESULT" | jq '.payload'
  exit 0
fi

if [ "$NEW_COUNT" -eq 0 ]; then
  printf 'post-review: every finding is already on %s#%s - nothing new to post (%s skipped).\n' \
    "$REPO" "$PR_NUMBER" "$DUP_COUNT"
  exit 0
fi

# --- post, as one atomic review -------------------------------------------------------------------
# One API call, not `gh pr review` plus a loop of comment posts: either the whole review lands or
# none of it does, so a rejected inline comment cannot leave half a review on the pull request.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/post-review.XXXXXX")"
cleanup() { [ -n "${TMPD:-}" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

printf '%s' "$RESULT" | jq '.payload' > "$TMPD/payload.json"

gh api --method POST \
  -H "Accept: application/vnd.github+json" \
  "repos/$REPO/pulls/$PR_NUMBER/reviews" \
  --input "$TMPD/payload.json" >/dev/null || fail 8 \
  "gh refused the review payload for $REPO#$PR_NUMBER. Nothing was posted."

printf 'post-review: posted %s to %s#%s - %s inline, %s in body, %s skipped as already present.\n' \
  "$EVENT" "$REPO" "$PR_NUMBER" "$INLINE_COUNT" "$BODY_COUNT" "$DUP_COUNT"
