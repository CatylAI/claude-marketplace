#!/usr/bin/env bash
# post-review.sh - post a finished code-review-core review to a GitLab merge request.
#
#   scripts/post-review.sh [--mr <iid>] [--project <group/project>] [--artifacts <dir>]
#                          [--dry-run] [--no-approve]
#
# Reads <artifacts>/VALIDATED.json (written by code-review-core's `contract.py finalize`), routes
# each finding to an inline diff note or the summary note, and posts them. It decides nothing about
# the code: no severity is changed, no verdict is computed when the document supplies one, and no
# finding is dropped.
#
# Refusals are the point. A missing or unparseable VALIDATED.json means the review did not finish,
# and a clean review posted over an unfinished run turns "we do not know" into an approval that a
# human will trust. Every such path exits non-zero and posts nothing.
#
# How a GitLab review is shaped (and why it is not the GitHub adapter with the names changed):
#
#   Position. An inline note needs a `position` carrying the diff version's three SHAs plus
#   old_path/new_path and the line. An ADDED line takes new_line only; an UNCHANGED (context) line
#   takes new_line AND old_line. Which one a cited line is, and whether it is in the diff at all,
#   comes from the MR diff version that matches the reviewed commit (CONTEXT.json reviewed_sha), so
#   the notes land on the lines that were reviewed even if the branch moved since.
#
#   Draft notes. Inline notes are created as drafts (invisible to others), each checked, then
#   published with ONE bulk_publish call that also carries the summary (`note`) and the reviewer
#   state (`reviewer_state`). A draft GitLab cannot anchor is deleted and its finding moves to the
#   summary; nothing is dropped. bulk_publish publishes ALL of this account's pending drafts, so any
#   pending draft that this script did not create is a refusal (exit 10), never swept into the post.
#
#   Approval. GitLab has an approval and the absence of one. APPROVE calls /approve with the reviewed
#   SHA, so GitLab refuses if the MR moved. When the verdict is anything else and this account's
#   approval is standing, it is withdrawn with /unapprove BEFORE posting.
#
# Safety. Findings are untrusted text. No value from the document is interpolated into a string the
# shell re-parses: jq carries every field into a JSON payload, the payload reaches glab through a
# file, and nothing here builds a command string or calls eval. Every rendered string also has `<!--`
# and `-->` broken with a zero-width space, so finding text can neither open an HTML comment nor
# forge one of the hidden markers this script reads back on the next run.
#
# Idempotency. Every posted finding carries a hidden fingerprint marker:
#     <!-- code-review-core:fp2:<P>:<T> -->
# <P> is the path parsed from `location` (verbatim), or the whole location, lowercased with
# whitespace collapsed, when it does not parse. <T> is the title, lowercased with whitespace
# collapsed. Both are URI-encoded. Category, line and id are left out on purpose: finalize can
# change the category, lines move, and finalize renumbers ids on every run. Matching is a multiset:
# N markers with one key mark at most N findings with that key as posted.
# Two older forms are still read, so an MR posted by an earlier version gets no duplicates:
#     <!-- code-review-core:fp:<category>~<path>~<title> -->
#     <!-- code-review-core:finding:<id> -->   (only when the same entry carries the title and location)
# Only PUBLISHED notes by this account count: a pending draft is not on the merge request, and
# anyone can quote a marker in a note of their own.
#
# The open set. The summary's fourth line lists a digest of the key of every finding in the document
# that wrote it:
#     <!-- code-review-core:active:<d> <d> ... -->   (d = two polynomial hashes of the key, "n.n")
# A marker older than your latest summary counts only while that summary lists its key (again as a
# multiset), so a finding that was fixed and later comes back is posted again. A marker newer than
# it (a run whose summary did not post) always counts. When the open set changes, a summary is
# posted even with no new finding and the same verdict. A summary without the line (an earlier
# version) leaves every marker counting.
#
# The verdict. The summary note starts with a fixed header whose third line is
#     <!-- code-review-core:verdict:<APPROVE|REQUEST_CHANGES|INCOMPLETE|DERIVED-<event>> -->
# and only that position is read back (the open set is the fourth). When the newest summary of yours
# carries a different verdict, a summary is posted even if every finding is already there.
#
# Test seams: GLAB_BIN overrides the glab binary; POST_REVIEW_MAX_BODY overrides the body cap.
# Portable bash 3.2+ / zsh: no mapfile, no `declare -A`, no ${var^^}. jq 1.6+.
set -euo pipefail

GLAB="${GLAB_BIN:-glab}"

ARTIFACTS=".code-review"
MR_IID=""
PROJECT=""
DRY_RUN=0
NO_APPROVE=0

# GitLab rejects a note over 1,000,000 characters. The summary is kept well under that; one inline
# note's evidence and recommendation are each clipped at 20,000.
MAX_BODY="${POST_REVIEW_MAX_BODY:-900000}"
MAX_FIELD=20000

fail() { # <exit-code> <message...>
  code="$1"; shift
  printf 'post-review: %s\n' "$*" >&2
  exit "$code"
}
note() { printf 'post-review: note: %s\n' "$*" >&2; }

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
  CODE_REVIEW_BLOCKING_FLOOR   BLOCKER|MAJOR|MINOR|NIT. Used only when the document carries no
                               verdict (a hand-built document). When VALIDATED.json has a verdict,
                               its `blocking_floor` is the floor, and a disagreeing value here is
                               reported on stderr and otherwise ignored.

Exit status: 0 posted (or nothing new to post). Non-zero means nothing was posted, with the reason
on stderr, except:
  12  the inline notes published but the summary did not (re-run to post it)
  13  the review posted but the approval call failed
Other codes: 2 arguments, 3 no jq, 4-7 artifact problems, 8 could not read the MR or what is on it,
9 an INCOMPLETE that reached APPROVE, 10 pending drafts of yours or a draft GitLab refused,
11 bulk_publish failed (nothing visible), 14 a standing approval could not be withdrawn.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mr)         [ $# -ge 2 ] || fail 2 "--mr needs an IID"; MR_IID="$2"; shift 2 ;;
    --project)    [ $# -ge 2 ] || fail 2 "--project needs <group/project>"; PROJECT="$2"; shift 2 ;;
    --artifacts)  [ $# -ge 2 ] || fail 2 "--artifacts needs a directory"; ARTIFACTS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-approve) NO_APPROVE=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            fail 2 "unknown argument: $1 (try --help)" ;;
  esac
done

case "$MR_IID" in
  "") ;;
  *[!0-9]*) fail 2 "--mr must be a number, got: $MR_IID" ;;
esac
case "$MAX_BODY" in ""|*[!0-9]*) fail 2 "POST_REVIEW_MAX_BODY must be a number" ;; esac

# --- jq is not optional -------------------------------------------------------------------------
# Parsing this document with sed would mean parsing attacker-influenced JSON with a line-oriented
# tool. Refusing is the only correct behaviour when jq is absent.
command -v jq >/dev/null 2>&1 || fail 3 \
  "jq is required and was not found on PATH. Install jq and re-run. Nothing was posted."

# --- the completion signal ----------------------------------------------------------------------
VALIDATED="$ARTIFACTS/VALIDATED.json"
[ -f "$VALIDATED" ] || fail 4 \
  "$VALIDATED does not exist, so the review did not finish. Run code-review-core's pipeline through finalize first. Nothing was posted."
jq empty "$VALIDATED" >/dev/null 2>&1 || fail 5 \
  "$VALIDATED is not parseable JSON, so the review did not finish cleanly. Nothing was posted."

FINDING_COUNT="$(jq '(.findings // []) | length' "$VALIDATED" 2>/dev/null)" || fail 5 \
  "$VALIDATED has no readable .findings array. Nothing was posted."
case "$FINDING_COUNT" in
  ""|*[!0-9]*) fail 5 "$VALIDATED has no readable .findings array. Nothing was posted." ;;
esac
DOC_VERDICT="$(jq -r '.verdict // "" | tostring' "$VALIDATED" 2>/dev/null)" || DOC_VERDICT=""
case "$DOC_VERDICT" in
  ""|APPROVE|REQUEST_CHANGES|INCOMPLETE) ;;
  *) fail 5 "$VALIDATED has verdict '$DOC_VERDICT', which is not APPROVE, REQUEST_CHANGES or INCOMPLETE. Nothing was posted." ;;
esac

if [ "$FINDING_COUNT" -eq 0 ] && [ -z "$DOC_VERDICT" ]; then
  fail 7 "$VALIDATED has zero findings AND no verdict - that is an empty result, not an approval. Nothing was posted."
fi

# --- the blocking floor -------------------------------------------------------------------------
# With a verdict present, the floor already did its work inside `finalize`, which recorded it as
# `blocking_floor` and listed the resulting ids in `blocking_reason_ids`. Re-deciding here with a
# different floor would label findings "blocking" that did not produce the verdict, so the env value
# can only warn. Without a verdict (a hand-built document), the env value decides, default MINOR.
ENV_FLOOR="$(printf '%s' "${CODE_REVIEW_BLOCKING_FLOOR:-}" | tr '[:lower:]' '[:upper:]')"
case "$ENV_FLOOR" in
  ""|BLOCKER|MAJOR|MINOR|NIT) ;;
  *) fail 6 "CODE_REVIEW_BLOCKING_FLOOR must be BLOCKER, MAJOR, MINOR or NIT; got: $ENV_FLOOR. Nothing was posted." ;;
esac
DOC_FLOOR="$(jq -r '(.blocking_floor // "") | if type == "string" then ascii_upcase else "" end' \
  "$VALIDATED" 2>/dev/null)" || DOC_FLOOR=""
case "$DOC_FLOOR" in BLOCKER|MAJOR|MINOR|NIT) ;; *) DOC_FLOOR="" ;; esac

if [ -n "$DOC_VERDICT" ]; then
  FLOOR="${DOC_FLOOR:-}"
  if [ -n "$ENV_FLOOR" ] && [ "$ENV_FLOOR" != "$DOC_FLOOR" ]; then
    note "CODE_REVIEW_BLOCKING_FLOOR=$ENV_FLOOR is ignored: the verdict in $VALIDATED was computed at ${DOC_FLOOR:-an unrecorded floor}. Re-run finalize with --floor $ENV_FLOOR to change it."
  fi
else
  FLOOR="${ENV_FLOOR:-${DOC_FLOOR:-MINOR}}"
fi

# --- scratch space --------------------------------------------------------------------------------
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/post-review.XXXXXX")"
cleanup() { [ -n "${TMPD:-}" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

# The commit the review was run against, from prepare-context.sh.
REVIEWED_SHA=""
if [ -f "$ARTIFACTS/CONTEXT.json" ]; then
  REVIEWED_SHA="$(jq -r '.reviewed_sha // "" | tostring' "$ARTIFACTS/CONTEXT.json" 2>/dev/null || true)"
  printf '%s' "$REVIEWED_SHA" | grep -Eq '^[0-9a-f]{40}$' || REVIEWED_SHA=""
fi

# --- glab plumbing ----------------------------------------------------------------------------------
# GitLab bodies carry raw control bytes often enough that jq dies at parse time on real MR titles.
# Everything read back is stripped before it reaches jq. A JSON string escapes a real control
# character, so nothing legitimate is lost.
strip_ctrl() { tr -d '\001-\010\013\014\016-\037'; }

# A read that fails closed: non-zero exit or unparseable output returns 1, and the caller refuses.
# --paginate prints one JSON array per page; callers slurp the file.
gl_read() { # <endpoint> <outfile> [--paginate]
  if [ "${3:-}" = "--paginate" ]; then
    "$GLAB" api --paginate "$1" > "$TMPD/raw.read" 2>"$TMPD/err" || return 1
  else
    "$GLAB" api "$1" > "$TMPD/raw.read" 2>"$TMPD/err" || return 1
  fi
  strip_ctrl < "$TMPD/raw.read" > "$2"
  jq -s -e 'length > 0' "$2" >/dev/null 2>&1 || { printf 'unparseable response\n' > "$TMPD/err"; return 1; }
}

# A write. GL_STATUS is the status line ("HTTP/1.1 201 Created") or empty when glab emitted none;
# the body lands in $TMPD/body. `-i` is what makes the status available at all.
GL_STATUS=""
gl_write() { # <method> <endpoint> [input-file]
  _method="$1"; _endpoint="$2"; _input="${3:-}"
  : > "$TMPD/raw"
  if [ -n "$_input" ]; then
    "$GLAB" api --method "$_method" --header "Content-Type: application/json" \
      --input "$_input" -i "$_endpoint" > "$TMPD/raw" 2>&1 || true
  else
    "$GLAB" api --method "$_method" -i "$_endpoint" > "$TMPD/raw" 2>&1 || true
  fi
  tr -d '\r' < "$TMPD/raw" > "$TMPD/raw.nocr"
  GL_STATUS="$(sed -n 's|^\(HTTP/[0-9.]* [0-9][0-9][0-9]\).*|\1|p' "$TMPD/raw.nocr" | head -1)"
  if [ -n "$GL_STATUS" ]; then
    awk 'seen { print } /^$/ { seen = 1 }' "$TMPD/raw.nocr" | strip_ctrl > "$TMPD/body"
  else
    strip_ctrl < "$TMPD/raw.nocr" > "$TMPD/body"
  fi
  return 0
}
status_is() { # <glob, e.g. 2??>
  case "$GL_STATUS" in HTTP/*\ $1) return 0 ;; *) return 1 ;; esac
}
short_body() { head -c 300 "$TMPD/body" | tr '\n' ' '; }

# --- what is already on the merge request ---------------------------------------------------------
printf '%s' '{"notes": [], "max_id": 0, "has_approved": false, "can_approve": true}' > "$TMPD/existing.json"
printf 'null' > "$TMPD/linemap.json"
printf '%s' '{"base_sha": "<diff version base_sha>", "start_sha": "<diff version start_sha>", "head_sha": "<diff version head_sha>"}' > "$TMPD/refs.json"
ME=""
MR_HEAD=""
ANCHOR_NOTE=""
PROJECT_REF=""
MR_BASE=""

if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$GLAB" >/dev/null 2>&1 || fail 8 \
    "the glab CLI is required to post and was not found on PATH. Re-run with --dry-run to see the plan. Nothing was posted."

  # glab api has no --repo: the project is part of the path. `:id` is glab's placeholder for the
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

  gl_read "$MR_BASE" "$TMPD/mr.json" && jq -e 'type == "object"' "$TMPD/mr.json" >/dev/null 2>&1 || fail 8 \
    "could not read $MR_BASE: $(head -c 300 "$TMPD/err"). Check 'glab auth status' and the project path. Nothing was posted."
  MR_HEAD="$(jq -r '.diff_refs.head_sha // ""' "$TMPD/mr.json")"
  if ! jq -e '(.diff_refs.base_sha // "") != "" and (.diff_refs.start_sha // "") != "" and (.diff_refs.head_sha // "") != ""' \
       "$TMPD/mr.json" >/dev/null 2>&1; then
    fail 8 "the merge request carries no usable diff_refs (base_sha/start_sha/head_sha), so no finding can be anchored to a line. Nothing was posted."
  fi

  ME="$("$GLAB" api user 2>/dev/null | strip_ctrl | jq -r '.username // ""' 2>/dev/null || true)"

  # The diff version to anchor to: the one whose head is the reviewed commit, else the latest.
  gl_read "$MR_BASE/versions" "$TMPD/versions.json" --paginate || fail 8 \
    "could not read the diff versions of $MR_BASE: $(head -c 300 "$TMPD/err"). Nothing was posted."
  VERSION_ID="$(jq -s -r --arg r "$REVIEWED_SHA" '[.[] | if type == "array" then .[] else . end] as $v
      | (if $r == "" then ($v | first) else ($v | map(select(.head_commit_sha == $r)) | first) end) // {}
      | .id // "" | tostring' "$TMPD/versions.json")"
  case "$VERSION_ID" in
    "")
      if [ -n "$REVIEWED_SHA" ]; then
        ANCHOR_NOTE="The reviewed commit ($REVIEWED_SHA) is not one of this merge request's diff versions (it was never pushed, or the branch was rewritten), so no finding is anchored inline."
        printf '{}' > "$TMPD/linemap.json"
        printf '%s' '{"base_sha": "", "start_sha": "", "head_sha": ""}' > "$TMPD/refs.json"
      else
        fail 8 "$MR_BASE has no diff versions to anchor notes to. Nothing was posted."
      fi ;;
    *[!0-9]*) fail 8 "unexpected diff version id '$VERSION_ID'. Nothing was posted." ;;
    *)
      gl_read "$MR_BASE/versions/$VERSION_ID" "$TMPD/version.json" || fail 8 \
        "could not read diff version $VERSION_ID of $MR_BASE: $(head -c 300 "$TMPD/err"). Nothing was posted."
      jq '{base_sha: .base_commit_sha, start_sha: .start_commit_sha, head_sha: .head_commit_sha}' \
        "$TMPD/version.json" > "$TMPD/refs.json"
      # new_path -> {old_path, lines: {"<new_line>": <old_line or null>}}. A `+` line maps to null
      # (added: new_line only); a context line maps to its old number (unchanged: both lines).
      # A line that is not in the map is not in the diff and cannot carry an inline note.
      jq '
        reduce (.diffs // [])[] as $d ({};
          .[$d.new_path] = {
            old_path: $d.old_path,
            lines: ((($d.diff // "") | split("\n")) | reduce .[] as $l ({o: 0, n: 0, m: {}};
              if ($l | startswith("@@")) then
                (($l | capture("^@@ -(?<o>[0-9]+)(?:,[0-9]+)? \\+(?<n>[0-9]+)")) // null) as $h
                | if $h == null then . else .o = ($h.o | tonumber) | .n = ($h.n | tonumber) end
              elif .n == 0 or $l == "" or ($l | startswith("\\")) then .
              elif ($l | startswith("+")) then .m[(.n | tostring)] = null | .n += 1
              elif ($l | startswith("-")) then .o += 1
              else .m[(.n | tostring)] = .o | .n += 1 | .o += 1 end) | .m) })' \
        "$TMPD/version.json" > "$TMPD/linemap.json" 2>/dev/null || fail 8 \
        "could not read the diff of version $VERSION_ID. Nothing was posted." ;;
  esac

  # Fail closed: a read-back that silently returns nothing makes every finding look new, and the
  # whole review is posted a second time.
  gl_read "$MR_BASE/notes" "$TMPD/notes.json" --paginate || fail 8 \
    "could not read the existing notes on $MR_BASE, so a post could duplicate them: $(head -c 300 "$TMPD/err"). Nothing was posted."
  gl_read "$MR_BASE/draft_notes" "$TMPD/drafts.json" --paginate || fail 8 \
    "could not read your pending draft notes on $MR_BASE, and bulk_publish would publish them: $(head -c 300 "$TMPD/err"). Nothing was posted."
  gl_read "$MR_BASE/approvals" "$TMPD/approvals.json" || fail 8 \
    "could not read the approval state of $MR_BASE, so a standing approval could not be withdrawn: $(head -c 300 "$TMPD/err"). Nothing was posted."

  # Pending drafts: bulk_publish publishes every one of them. Leftovers from a killed run of this
  # script (they carry its marker) are deleted; anything else is yours and is not ours to publish.
  jq -s -r '[.[] | if type == "array" then .[] else . end]
      | map(select((.note // "") | tostring | contains("<!-- code-review-core:"))) | .[].id | tostring' \
    "$TMPD/drafts.json" > "$TMPD/stale-drafts.txt"
  OTHER_DRAFTS="$(jq -s -r '[.[] | if type == "array" then .[] else . end]
      | map(select((.note // "") | tostring | contains("<!-- code-review-core:") | not)) | map(.id | tostring) | join(" ")' \
    "$TMPD/drafts.json")"
  if [ -n "$OTHER_DRAFTS" ]; then
    fail 10 "you have pending draft notes on $MR_BASE (ids: $OTHER_DRAFTS), and bulk_publish would publish them with this review. Submit them in the web UI, or delete each with: glab api --method DELETE $MR_BASE/draft_notes/<id> - then re-run. Nothing was posted."
  fi
  while IFS= read -r _did; do
    case "$_did" in ""|*[!0-9]*) continue ;; esac
    gl_write DELETE "$MR_BASE/draft_notes/$_did"
    status_is '2??' || fail 10 "could not delete a leftover draft ($_did) from an earlier run: ${GL_STATUS:-no status} $(short_body). Delete it with: glab api --method DELETE $MR_BASE/draft_notes/$_did - then re-run. Nothing was posted."
    note "deleted leftover draft $_did from an earlier run that did not publish."
  done < "$TMPD/stale-drafts.txt"

  jq -n --slurpfile n "$TMPD/notes.json" --slurpfile a "$TMPD/approvals.json" '
      [$n[] | if type == "array" then .[] else . end | select(type == "object") | select(.system != true)] as $notes
      | { notes: [$notes[] | { id: (.id // 0), body: (.body // "" | tostring),
                               author: (.author.username // ""),
                               path: (.position.new_path // null) }],
          max_id: ([$notes[].id // 0] | max // 0),
          has_approved: ($a[0].user_has_approved == true),
          can_approve: ($a[0].user_can_approve != false) }' \
    > "$TMPD/existing.json" 2>/dev/null || fail 8 \
    "the existing notes or approvals on $MR_BASE did not parse as JSON, so a post could duplicate them. Nothing was posted."
fi

# --- routing, body and payloads, computed entirely inside jq ------------------------------------
JQ_PROG="$(cat <<'JQPROG'
def rank: {"BLOCKER":4,"MAJOR":3,"MINOR":2,"NIT":1}[(. // "") | tostring | ascii_upcase] // 0;
def sev: ((.severity // "MINOR") | tostring | ascii_upcase);
def conf: ((.confidence // "HIGH") | tostring | ascii_upcase);
# Break HTML-comment syntax in untrusted text with a zero-width space. It renders the same, and it
# means no finding can open a comment or forge a marker. Applied to every string before rendering.
def defang: (. // "") | tostring | gsub("<!--"; "<​!--") | gsub("-->"; "--​>");
def oneline: (. // "") | tostring | gsub("[\n\r]"; " ");
def clip($n): (. // "") | tostring | if length > $n then .[0:$n] + " ...(truncated)" else . end;
def slug: (. // "") | tostring | ascii_downcase | gsub("[^a-z0-9._/]+"; "-") | gsub("^-+|-+$"; "");
def parseloc:
  ((((.location // "") | tostring | capture("^(?<p>[^:\\s]+)(?::|\\s+(?:[Ll]ine\\s+)?)(?<n>[0-9]+)"))?) // null);
# Fingerprint (see the header). @uri leaves !*'() alone in jq 1.6 and encodes them in 1.7, so they
# are encoded explicitly: the same finding must give the same key whichever jq wrote it.
def normtext: (. // "") | tostring | ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def enc: @uri | gsub("!"; "%21") | gsub("\\*"; "%2A") | gsub("'"; "%27") | gsub("\\("; "%28") | gsub("\\)"; "%29");
def fingerprint:
  ((if ._loc != null then ._loc.p else (.location | normtext) end) | enc) + ":" + ((.title // "") | normtext | enc);
def legacy_fingerprint:
  ((.category // "review") | slug) + "~"
  + ((._loc.p // .location // "") | slug | .[0:120]) + "~"
  + ((.title // "") | slug | .[0:80]);
def fpmark: "<!-- code-review-core:fp2:" + ._fp + " -->";
def vmark($k): "<!-- code-review-core:verdict:" + $k + " -->";
# The open set is written as a short digest of each fp2 key, so it stays small next to the size
# limit: two polynomial hashes of the key's code points, each below 2^26, joined by a dot. Every
# intermediate value stays below 2^53, so jq's doubles compute it exactly on every version.
def phash($b; $m): explode | reduce .[] as $c (0; (. * $b + $c) % $m);
def digest: "\(phash(31; 67108859)).\(phash(131; 67108837))";
def amark($keys): "<!-- code-review-core:active:" + ($keys | join(" ")) + " -->";
def fp2re: "<!-- code-review-core:fp2:([A-Za-z0-9%._~-]*:[A-Za-z0-9%._~-]*) -->";
def activere: "^## Code review\n\n<!-- code-review-core:verdict:[A-Z_-]+ -->\n<!-- code-review-core:active:(?<a>[0-9. ]*) -->(\n|$)";
def fp1re: "<!-- code-review-core:fp:([a-z0-9._/~-]+) -->";
def counts: group_by(.) | map({key: .[0], value: length}) | from_entries;
def tally($posts; $re): [$posts[] | .body | scan($re) | .[0]] | counts;
# The first version's `finding:<id>` markers, each with the text of its own entry (from the
# previous marker up to this one), so a match can check that entry's title and location.
def idtokens($p):
  (split("<!-- code-review-core:finding:")) as $parts
  | [ range(1; $parts | length) as $i
      | ([$parts[$i] | capture("^(?<id>[A-Za-z0-9._:/-]+) -->")] | first) as $m
      | select($m != null)
      | { id: $m.id, path: $p,
          seg: (if $i == 1 then $parts[0]
                else ($parts[$i - 1] | (index(" -->")) as $x | if $x == null then . else .[($x + 4):] end) end) } ];
def idmatch($t):
  . as $f
  | ($t.id == (($f.id // "") | tostring)) and ($f._t != "")
    and (if $t.path != null
         then ($t.path == ($f._loc.p // "")) and ($t.seg | contains("** " + $f._t + "\n"))
         else ($t.seg | contains("\n  " + $f._t + "  \n")) and ($t.seg | contains("`" + $f._l + "`")) end);
# The contract's predicate (contract.py _in_scope_at_floor), used ONLY for a document with no
# verdict. A document with a verdict is never re-judged: its blocking_reason_ids are the list.
def in_scope($flr): (.in_diff != false) and ((sev | rank) >= 2)
                    and ((.ux_impact == true) or ((sev | rank) >= $flr));
def blocks($flr):    in_scope($flr) and (conf == "HIGH");
def escalates($flr): in_scope($flr) and (conf != "HIGH");
def shortentry:
  if ._missing then "- `\(.id)` (named by blocking_reason_ids; not among the findings)"
  else "- **\(sev)** `\((.location // "n/a") | oneline)` \((.title // "(untitled)") | oneline)" end;
def bodyentry($compact):
  "- **\(sev)** / \(.category // "review") / `\((.location // "n/a") | oneline)`  \n"
  + "  \((.title // "(untitled)") | oneline)  \n"
  + (if $compact then "" else
       (if ((.evidence // "") | length) > 0 then "  Evidence: \(.evidence | oneline | clip(2000))  \n" else "" end)
     + (if ((.recommendation // "") | length) > 0 then "  Recommendation: \(.recommendation | oneline | clip(2000))  \n" else "" end)
     end)
  + "  _finding `\(.id // "?")`, confidence: \(.confidence // "?"), in_diff: \(.in_diff), ux_impact: \(.ux_impact)_  \n"
  + "  " + fpmark;
def inlinebody:
  "**\(sev) / \(.category // "review")** \((.title // "(untitled)") | oneline)\n\n"
  + (if ((.evidence // "") | length) > 0 then "\(.evidence | clip($maxfield))\n\n" else "" end)
  + (if ((.recommendation // "") | length) > 0 then "**Recommendation:** \(.recommendation | clip($maxfield))\n\n" else "" end)
  + "_confidence: \(.confidence // "?"), finding `\(.id // "unknown")`_\n"
  + fpmark;
def section($title; $intro; $items; $compact):
  if ($items | length) > 0 then [ $title, "" ] + (if $intro == "" then [] else [ $intro, "" ] end)
       + ($items | map(bodyentry($compact))) + [ "" ]
  else [] end;
def landed: [scan(fp2re)] | length;
# Where a parsed location sits in the diff version: null when GitLab has no such line in the diff.
def anchor:
  if $lines == null then {old_path: ._loc.p, old_line: null}
  else ._loc.n as $n | ._loc.p as $p | ($lines[$p] // null) as $file
    | if $file == null or ($file.lines | has($n) | not) then null
      else {old_path: ($file.old_path // $p), old_line: $file.lines[$n]} end
  end;

($ex[0]) as $E
# Only what this account posted counts: anyone can quote a marker in a note of their own. When the
# account is unknown (`glab api user` failed), every note is read.
| ([$E.notes[] | select($me == "" or .author == $me) | {rid: .id, body, path}]) as $mine
| def ours: (.body | startswith("## Code review"));
  ([$mine[] | select(ours)] | sort_by(.rid) | last) as $lastown
| (if $lastown == null then null
   else ([$lastown.body | capture("^## Code review\n\n<!-- code-review-core:verdict:(?<v>[A-Z_-]+) -->(\n|$)") | .v] | first) as $nv
      | ([$lastown.body | capture("<!-- code-review-core:finding:verdict-(?<v>[A-Z_-]+) -->\\s*$") | .v] | first) as $lv
      | ([$lastown.body | capture("^## Code review\n\nVerdict: \\*\\*(?<v>[A-Z_]+)\\*\\*") | .v] | first) as $ov
      | ([$lastown.body | capture("^## Code review\n\nNo `verdict` in the document - event derived[^`]*`[^`]*`: `(?<v>[A-Z_]+)`") | .v] | first) as $dv
      | (if $nv != null then $nv elif $lv != null then $lv elif $ov != null then $ov
         elif $dv != null then "DERIVED-" + $dv else null end)
   end) as $last
# The open set: the fp2 keys of every finding in the document that wrote your latest summary. A
# marker older than that summary counts only while its key is still open, so a finding that was
# fixed and later comes back is posted again. Markers newer than it (a run whose summary did not
# post) always count. null when that summary predates the open set.
| ($lastown.rid // 0) as $lid
| (if $lastown == null then null
   else ([$lastown.body | capture(activere) | .a | split(" ") | map(select(. != ""))] | first) end) as $active
| ([$mine[] | select(.rid > $lid)]) as $fresh
| ([$mine[] | select(.rid <= $lid)]) as $stale
| {f: tally($fresh; fp2re), s: tally($stale; fp2re)} as $c2
| {f: tally($fresh; fp1re), s: tally($stale; fp1re)} as $c1
| ([ $mine[] | (.rid > $lid) as $fr | .path as $p | .body | idtokens($p) | .[] | . + {fresh: $fr} ]
   | to_entries | map(.value + {i: .key})) as $idt
# Take one marker for finding $f from the fresh ("f") or older ("s") notes; sets .hit.
| def consume($f; $fr):
    if (.c2[$fr][$f._fp] // 0) > 0 then .c2[$fr][$f._fp] -= 1 | .hit = true
    elif (.c1[$fr][$f._lfp] // 0) > 0 then .c1[$fr][$f._lfp] -= 1 | .hit = true
    else . as $s
      | ([$idt[] | select(.fresh == ($fr == "f")) | select(.i as $i | any($s.used[]; . == $i) | not)
                 | select(. as $t | $f | idmatch($t)) | .i] | first) as $h
      | if $h != null then .used += [$h] | .hit = true else .hit = false end
    end;
  . as $raw
| ($raw | walk(if type == "string" then defang else . end)) as $doc
| ($floor | ascii_upcase) as $fl
| (if $fl == "" then 2 else ($fl | rank) end) as $flr
| ($raw.verdict // "") as $verdict
# Keys come from the raw finding (it is what a later run will see); everything rendered comes from
# the defanged copy.
| ([ ($raw.findings // []) | to_entries[] | select(.value | type == "object")
     | .key as $k | .value
     | (. + {_loc: parseloc}) as $r
     | ($doc.findings[$k] + { _k: $k,
                              _loc: $r._loc,
                              _fp: ($r | fingerprint),
                              _dg: ($r | fingerprint | digest),
                              _lfp: ($r | legacy_fingerprint),
                              _t: (($r.title // "") | oneline),
                              _l: (($r.location // "n/a") | oneline) }) ]) as $all
| (if   $verdict == "REQUEST_CHANGES" then "REQUEST_CHANGES"
   elif $verdict == "APPROVE"         then "APPROVE"
   elif $verdict == "INCOMPLETE"      then "COMMENT"
   elif ($all | any(blocks($flr)))    then "REQUEST_CHANGES"
   else "COMMENT" end) as $event
| (if $verdict == "" then "DERIVED-" + $event else $verdict end) as $vkey
# The approval: only APPROVE has one, and only on the reviewed commit.
| (if $event != "APPROVE" then {call: false, why: null}
   elif $noapprove then {call: false, why: "--no-approve was passed"}
   elif $shaok != "" then {call: false, why: $shaok}
   # Before can_approve: GitLab reports user_can_approve false once this account has approved.
   elif $E.has_approved then {call: false, why: null}
   elif $E.can_approve == false then {call: false,
        why: "GitLab does not let this account approve this merge request (its approval rules, or it is the author's own merge request)"}
   else {call: true, why: null} end) as $ap
| ($E.has_approved and ($event != "APPROVE")) as $unapprove
| (if $event == "REQUEST_CHANGES" then "requested_changes"
   elif $event == "APPROVE" then "reviewed" else null end) as $rstate
| (($last != null) and ($last == $vkey)) as $same_verdict
# Multiset match: each marker accounts for one finding, newest form first. A marker newer than your
# latest summary counts outright; an older one also needs its key open in that summary.
| (reduce $all[] as $f ({c2: $c2, c1: $c1, cap: (($active // []) | counts), used: [], out: []};
     consume($f; "f")
     | if .hit then .out += [$f + {_posted: true}]
       elif ($active != null) and ((.cap[$f._dg] // 0) <= 0) then .out += [$f + {_posted: false}]
       else consume($f; "s")
         | if .hit then .cap[$f._dg] = ((.cap[$f._dg] // 0) - 1) | .out += [$f + {_posted: true}]
           else .out += [$f + {_posted: false}] end
       end)) as $m
| $m.out as $ann
| ($all | map(._dg) | sort) as $keys
# A summary is also needed when the open set changed, or when it was never recorded and a posted
# finding is gone, so the next run knows that finding is closed.
| (if $active != null then ($active | sort) != $keys
   else ([$m.c2.f[], $m.c2.s[], $m.c1.f[], $m.c1.s[]] | any(. > 0)) end) as $set_changed
| (if $active == null then 0
   else (($keys | counts) as $kc | [($active | counts) | to_entries[] | .value - ($kc[.key] // 0) | select(. > 0)] | add // 0) end) as $gone
| ($ann | map(select(._posted | not))) as $new
| ($ann | map(select(._posted))) as $dup
| ($new | map(select((.in_diff == true) and (._loc != null)) | . + {_a: anchor})) as $cand
| ($cand | map(select((._a != null) and (. as $f | $forcemove | index($f._k) | not)))) as $inline
| ($cand | map(select((._a == null) or (. as $f | $forcemove | index($f._k))))) as $moved
| ($new | map(select((.in_diff != true) or  (._loc == null)))) as $bodyf
| ((($new | length) > 0) or ($same_verdict | not) or $set_changed) as $post_needed
| (if $verdict != "" then (($doc.blocking_reason_ids // []) | map(tostring))
   else ($all | map(select(blocks($flr) or escalates($flr))) | map(.id // "?")) end) as $reason_ids
| ($reason_ids | map(. as $i | (($all | map(select(.id == $i)) | first) // {id: $i, _missing: true}))) as $reasons
| ($doc.incomplete_inputs // []) as $incomplete
| (($doc.coverage_notes // []) | map(oneline | clip(500))) as $cov
| (($doc.decision_errors // []) | map("- `\(.source_id // "?")`: \(.error // "" | oneline | clip(500))")) as $derr
| def mkbody($compact):
    [ "## Code review", "", vmark($vkey), amark($keys), "",
      (if $verdict == ""
       then "No `verdict` in the document - event derived at floor `\($fl)`: `\($event)`."
       else "Verdict: **\($verdict)**" + (if $fl == "" then "" else " (blocking floor `\($fl)`)" end) + "." end),
      "" ]
    + (if $ap.why != null then
         [ "**Not approved by this post:** \($ap.why). The verdict above stands.", "" ]
       else [] end)
    + (if $event == "REQUEST_CHANGES" then
         [ "**Changes are requested.** This merge request is deliberately left unapproved by this review.", "" ]
       else [] end)
    + [ "\($all | length) finding(s) in `VALIDATED.json` - "
          + ([ "BLOCKER", "MAJOR", "MINOR", "NIT" ]
             | map(. as $s | "\($all | map(select(sev == $s)) | length) \($s)") | join(", ")) + ".", "" ]
    + (if $verdict == "INCOMPLETE" then
         [ "**This review is incomplete.** It is posted as a comment - not an approval and not a rejection." ]
         + (if ($incomplete | length) > 0 then
              [ "Inputs the pipeline could not read:" ]
              + ($incomplete | map("- `\(.input // "?")`: \(.problem // "" | oneline)"))
            else [] end)
         + [ "" ]
       else [] end)
    + (if ($reasons | length) > 0 then
         [ (if $verdict == "REQUEST_CHANGES" then "### Blocking - the findings behind REQUEST_CHANGES"
            elif $verdict == "INCOMPLETE" then "### Needs a human - findings the validator could not resolve"
            else "### Blocking or unresolved - derived at `\($fl)` (the document has no verdict)" end), "" ]
         + ($reasons | map(shortentry)) + [ "" ]
       else [] end)
    + (if ($inline | length) > 0 then [ "\($inline | length) finding(s) are attached inline to the lines they cite.", "" ] else [] end)
    + section("### Pre-existing - not introduced by this diff";
              "These keep their severity; being out of scope is what stops them blocking.";
              ($bodyf | map(select(.in_diff != true))); $compact)
    + section("### Could not be placed on a line";
              "These cite this diff, but their `location` did not parse into a path and a line.";
              ($bodyf | map(select(.in_diff == true))); $compact)
    + section("### Could not be anchored inline";
              (if $anchor_note != "" then ($anchor_note | defang)
               else "The cited line is not in the merge request diff GitLab has for the reviewed commit, or GitLab would not anchor a note there, so they are listed here." end);
              $moved; $compact)
    + (if ($dup | length) > 0 then [ "_\($dup | length) finding(s) already present on this merge request were skipped._", "" ] else [] end)
    + (if $gone > 0 then [ "_\($gone) finding(s) reported by the previous review are no longer reported._", "" ] else [] end)
    + (if ($cov | length) > 0 then [ "### Coverage notes", "" ] + ($cov | map("- " + .)) + [ "" ] else [] end)
    + (if ($derr | length) > 0 then [ "### Validator decision errors", "" ] + $derr + [ "" ] else [] end)
    | join("\n");
  # Over the cap even when compact: cut at the last whole entry, so no finding is half-shown and
  # every finding that is shown has its marker. The ones cut off are posted by the next run.
  def fitbody:
    mkbody(false) as $b
    | if ($b | length) <= $maxbody then $b
      else mkbody(true) as $c
      | if ($c | length) <= $maxbody then $c
        else ($c[0:($maxbody - 300)]) as $cut
          | ($cut | rindex("\n- **")) as $at
          | (if $at == null then $cut else $cut[0:$at] end)
            + "\n\n_Summary truncated to fit GitLab's note size limit. The findings cut off here are posted by the next run._"
        end
      end;

  (($inline | map("inline  \(._loc.p):\(._loc.n)  [\(sev)] \(.id // "?") \((.title // "") | oneline)"
                  + (if $lines == null then "  (if that line is in the MR diff)" else "" end)))
   + ($moved | map("body    [\(sev)] \(.id // "?") \((.title // "") | oneline)  (reason: line not in the MR diff)"))
   + ($bodyf | map("body    [\(sev)] \(.id // "?") \((.title // "") | oneline)  (reason: "
                   + (if .in_diff != true then "in_diff=false" else "location did not parse" end) + ")"))
   + ($dup   | map("skip    \(.id // "?") already posted"))
   + (if ($same_verdict | not) and (($new | length) == 0)
      then [ "body    verdict-only summary (\($vkey); your last summary said \($last // "nothing"))" ]
      elif $same_verdict and (($new | length) == 0) and $set_changed
      then [ "body    summary for the changed set of open findings (\($gone) no longer reported)" ]
      else [] end)
   + (if $unapprove then [ "unapprove  your standing approval (the verdict is now \($vkey))" ] else [] end)
  ) as $plan
| fitbody as $body
| { event: $event,
    verdict: $verdict,
    vkey: $vkey,
    floor: $fl,
    plan: $plan,
    post_needed: $post_needed,
    approve: $ap.call,
    approve_why: $ap.why,
    unapprove: $unapprove,
    reviewer_state: $rstate,
    new_count: ($new | length),
    dup_count: ($dup | length),
    inline_count: ($inline | length),
    body_count: (($bodyf | length) + ($moved | length)),
    body_landed: ($body | landed),
    payload: {
      summary: ({ note: $body } + (if $rstate == null then {} else { reviewer_state: $rstate } end)),
      inline: ($inline | map({
        k: ._k,
        finding_id: (.id // "unknown"),
        draft: {
          note: inlinebody,
          position: ({
            base_sha:      $refs.base_sha,
            start_sha:     $refs.start_sha,
            head_sha:      $refs.head_sha,
            position_type: "text",
            new_path:      ._loc.p,
            old_path:      ._a.old_path,
            new_line:      (._loc.n | tonumber)
          } + (if ._a.old_line == null then {} else { old_line: ._a.old_line } end))
        }
      }))
    } }
JQPROG
)"

# The SHA to approve at, or the reason approving is off. Approving an MR whose head is not the
# reviewed commit would approve code nobody reviewed.
SHA_WHY=""
APPROVE_SHA="$MR_HEAD"
if [ -n "$REVIEWED_SHA" ] && [ -n "$MR_HEAD" ] && [ "$REVIEWED_SHA" != "$MR_HEAD" ]; then
  SHA_WHY="the merge request head ($MR_HEAD) is not the reviewed commit ($REVIEWED_SHA); re-run the review on the current head"
fi

RESULT_FILE="$TMPD/result.json"
route() { # <forcemove-json-array>
  jq --slurpfile ex "$TMPD/existing.json" --slurpfile lm "$TMPD/linemap.json" \
     --slurpfile rf "$TMPD/refs.json" --argjson forcemove "$1" \
     --arg floor "$FLOOR" --arg me "$ME" --arg shaok "$SHA_WHY" --arg anchor_note "$ANCHOR_NOTE" \
     --argjson noapprove "$([ "$NO_APPROVE" -eq 1 ] && echo true || echo false)" \
     --argjson maxbody "$MAX_BODY" --argjson maxfield "$MAX_FIELD" \
     "\$lm[0] as \$lines | \$rf[0] as \$refs | $JQ_PROG" "$VALIDATED" > "$RESULT_FILE" || fail 5 \
    "could not route the findings in $VALIDATED - the document does not match the agent contract. Nothing was posted."
  [ -s "$RESULT_FILE" ] || fail 5 "routing produced no output for $VALIDATED. Nothing was posted."
}
route '[]'

rget() { jq -r "$1" "$RESULT_FILE"; }
EVENT="$(rget '.event')"
VKEY="$(rget '.vkey')"
POST_NEEDED="$(rget '.post_needed')"
DUP_COUNT="$(rget '.dup_count')"
INLINE_COUNT="$(rget '.inline_count')"
WILL_APPROVE="$(rget '.approve')"
APPROVE_WHY="$(rget '.approve_why // ""')"
UNAPPROVE="$(rget '.unapprove')"
PLAN="$(rget '.plan[]?')"

# An INCOMPLETE verdict must never leave this script as an approval. Asserted rather than assumed.
if [ "$DOC_VERDICT" = "INCOMPLETE" ] && { [ "$EVENT" = "APPROVE" ] || [ "$WILL_APPROVE" = "true" ]; }; then
  fail 9 "refusing to post an INCOMPLETE review as an approval. Nothing was posted."
fi

# --- dry run: no glab call of any kind ---------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'post-review: DRY RUN - no GitLab API call will be made\n'
  printf '  project:        %s\n' "${PROJECT:-(resolved from origin at post time)}"
  printf '  merge request:  %s\n' "${MR_IID:-(the MR for the current branch)}"
  printf '  artifacts:      %s\n' "$VALIDATED"
  printf '  blocking floor: %s\n' "${FLOOR:-(not recorded in the document)}"
  printf '  verdict:        %s\n' "${DOC_VERDICT:-(absent, derived)}"
  printf '  review event:   %s\n' "$EVENT"
  printf '  approve call:   %s\n' "$([ "$WILL_APPROVE" = "true" ] && echo yes || echo no)"
  printf '  reviewed sha:   %s\n' "${REVIEWED_SHA:-(no CONTEXT.json; the latest diff version at post time)}"
  printf '  routing:        %s inline, %s in body, %s skipped\n' "$INLINE_COUNT" "$(rget '.body_count')" "$DUP_COUNT"
  printf '  note:           a dry run cannot see the MR diff, what is already posted, or a standing approval\n'
  printf '\nplan:\n'
  if [ -n "$PLAN" ]; then printf '%s\n' "$PLAN" | sed 's/^/  /'; else printf '  (nothing to post)\n'; fi
  printf '\npayload:\n'
  jq '.payload' "$RESULT_FILE"
  exit 0
fi

# --- withdraw a standing approval ------------------------------------------------------------------
# Posting a non-approval does not remove an earlier approval, so without this an INCOMPLETE run would
# leave the approval in place. It runs before the post: if the post then fails, the MR is left with
# no approval rather than a stale one.
if [ "$UNAPPROVE" = "true" ]; then
  gl_write POST "$MR_BASE/unapprove"
  if ! status_is '2??'; then
    fail 14 "could not withdraw your earlier approval of $MR_BASE (${GL_STATUS:-no status}: $(short_body)). The verdict is now $VKEY, and posting it would leave that approval standing. Run: glab api --method POST $MR_BASE/unapprove - then re-run. Nothing was posted."
  fi
  note "withdrew your earlier approval: the verdict is now $VKEY."
fi

approve_if_needed() {
  [ "$WILL_APPROVE" = "true" ] || return 0
  jq -n --arg s "$APPROVE_SHA" 'if $s == "" then {} else {sha: $s} end' > "$TMPD/approve.json"
  gl_write POST "$MR_BASE/approve" "$TMPD/approve.json"
  if ! status_is '2??'; then
    fail 13 "the review is on $MR_BASE but the approval did not land (${GL_STATUS:-no status}: $(short_body)). The merge request is NOT approved by this review. Approve it with: glab mr approve $MR_IID${APPROVE_SHA:+ --sha $APPROVE_SHA}"
  fi
}

if [ "$POST_NEEDED" != "true" ]; then
  approve_if_needed
  printf 'post-review: every finding and the verdict are already on %s - nothing new to post (%s skipped)%s.\n' \
    "$MR_BASE" "$DUP_COUNT" "$([ "$WILL_APPROVE" = "true" ] && echo ", approved" || echo "")"
  exit 0
fi

# --- inline notes, as unpublished drafts --------------------------------------------------------------
: > "$TMPD/created.txt"
discard_drafts() {
  while IFS= read -r _did; do
    [ -n "$_did" ] || continue
    gl_write DELETE "$MR_BASE/draft_notes/$_did"
  done < "$TMPD/created.txt"
}

# One draft per inline finding. A draft GitLab refuses as a position (400/422) or accepts with
# `position: null` (unanchored) is deleted and its finding moves to the summary. Any other failure
# means the API cannot be trusted right now: every draft is deleted and nothing is posted.
MOVED='[]'
I=0
while [ "$I" -lt "$INLINE_COUNT" ]; do
  jq --argjson i "$I" '.payload.inline[$i].draft' "$RESULT_FILE" > "$TMPD/note-$I.json"
  FID="$(jq -r --argjson i "$I" '.payload.inline[$i].finding_id' "$RESULT_FILE")"
  FK="$(jq -r --argjson i "$I" '.payload.inline[$i].k' "$RESULT_FILE")"
  gl_write POST "$MR_BASE/draft_notes" "$TMPD/note-$I.json"
  NOTE_ID="$(jq -r 'if type == "object" and (.id | type) == "number" then .id else "" end' "$TMPD/body" 2>/dev/null || true)"
  HAS_POS="$(jq -r 'if type == "object" and .position != null then "yes" else "no" end' "$TMPD/body" 2>/dev/null || true)"
  if status_is '2??' && [ -n "$NOTE_ID" ] && [ "$HAS_POS" = "yes" ]; then
    printf '%s\n' "$NOTE_ID" >> "$TMPD/created.txt"
  elif status_is '2??' && [ -n "$NOTE_ID" ]; then
    gl_write DELETE "$MR_BASE/draft_notes/$NOTE_ID"
    note "GitLab accepted the note for $FID but could not anchor it; it moves to the summary."
    MOVED="$(printf '%s' "$MOVED" | jq -c --argjson k "$FK" '. + [$k]')"
  elif status_is '400' || status_is '422'; then
    note "GitLab refused the position for $FID (${GL_STATUS}: $(short_body)); it moves to the summary."
    MOVED="$(printf '%s' "$MOVED" | jq -c --argjson k "$FK" '. + [$k]')"
  else
    discard_drafts
    fail 10 "creating the draft note for $FID failed (${GL_STATUS:-no status}: $(short_body)). The drafts this run created were deleted. Nothing was posted."
  fi
  I=$((I + 1))
done

if [ "$MOVED" != '[]' ]; then
  route "$MOVED"   # the kept drafts stay in the same order; the body gains the moved findings
fi
INLINE_COUNT="$(rget '.inline_count')"
BODY_COUNT="$(rget '.body_count')"
LANDED="$(rget '.body_landed')"

# --- publish: drafts, summary and reviewer state in one call ----------------------------------------
jq '.payload.summary' "$RESULT_FILE" > "$TMPD/publish.json"
jq '{body: .payload.summary.note}' "$RESULT_FILE" > "$TMPD/summary.json"

post_summary_note() { # the fallback: summary as an ordinary note
  gl_write POST "$MR_BASE/notes" "$TMPD/summary.json"
  status_is '2??' || fail 12 "the inline notes are published on $MR_BASE but the summary did not post (${GL_STATUS:-no status}: $(short_body)). Re-run: the inline notes are skipped and the summary is retried."
}

# GitLab applies reviewer_state only after the summary note is created, so every path that posts
# the summary separately has lost it. bulk_publish with no pending drafts publishes nothing and
# still sets the state. A re-run would not repair it (the verdict already matches), so it is set here.
set_reviewer_state() {
  jq -e '.payload.summary.reviewer_state != null' "$RESULT_FILE" >/dev/null 2>&1 || return 0
  jq '{reviewer_state: .payload.summary.reviewer_state}' "$RESULT_FILE" > "$TMPD/state.json"
  gl_write POST "$MR_BASE/draft_notes/bulk_publish" "$TMPD/state.json"
  status_is '2??' || note "could not set your reviewer state to $(jq -r '.reviewer_state' "$TMPD/state.json") (${GL_STATUS:-no status}: $(short_body)); set it in the merge request's reviewer panel."
}

# An older GitLab ignores `note` on bulk_publish without an error, so the summary is confirmed by
# reading back a newer note of ours that starts with the header.
summary_landed() {
  gl_read "$MR_BASE/notes" "$TMPD/after.json" --paginate || return 2
  jq -s -e --arg me "$ME" --argjson max "$(jq -r '.max_id' "$TMPD/existing.json")" \
    '[.[] | if type == "array" then .[] else . end | select(type == "object")]
     | any((.id // 0) > $max and ((.body // "") | startswith("## Code review"))
           and ($me == "" or (.author.username // "") == $me))' "$TMPD/after.json" >/dev/null 2>&1
}

pending_drafts() { # prints how many of our drafts are still pending, or "?" when unreadable
  if gl_read "$MR_BASE/draft_notes" "$TMPD/pending.json" --paginate; then
    jq -s -r '[.[] | if type == "array" then .[] else . end | select(type == "object")] | length' "$TMPD/pending.json"
  else
    printf '?'
  fi
}

gl_write POST "$MR_BASE/draft_notes/bulk_publish" "$TMPD/publish.json"
if status_is '2??'; then
  rc=0; summary_landed || rc=$?
  if [ "$rc" -eq 2 ]; then
    fail 12 "the review was published on $MR_BASE, but the notes could not be read back to confirm the summary. Check the merge request; a re-run posts the summary if it is missing."
  elif [ "$rc" -ne 0 ]; then
    note "this GitLab ignored the summary on bulk_publish; posting it as a note."
    post_summary_note
    set_reviewer_state
  fi
elif status_is '400'; then
  # An older GitLab that validates the parameters differently: publish plainly, then the summary.
  note "bulk_publish refused the summary and reviewer state (${GL_STATUS}); publishing without them."
  printf '{}' > "$TMPD/plain.json"
  gl_write POST "$MR_BASE/draft_notes/bulk_publish" "$TMPD/plain.json"
  if ! status_is '2??'; then
    discard_drafts
    fail 11 "bulk_publish failed (${GL_STATUS:-no status}: $(short_body)); the drafts this run created were deleted. Nothing is visible on the merge request."
  fi
  post_summary_note
  set_reviewer_state
else
  # 5xx before publishing leaves the drafts pending; a failure after it (the summary) does not.
  if [ "$(pending_drafts)" = "0" ]; then
    post_summary_note
    set_reviewer_state
  else
    discard_drafts
    fail 11 "bulk_publish failed (${GL_STATUS:-no status}: $(short_body)); the drafts this run created were deleted. Nothing is visible on the merge request."
  fi
fi

approve_if_needed

printf 'post-review: posted %s to %s - %s inline, %s in the summary, %s skipped as already present%s%s.\n' \
  "$VKEY" "$MR_BASE" "$INLINE_COUNT" "$LANDED" "$DUP_COUNT" \
  "$([ "$WILL_APPROVE" = "true" ] && echo ", approved" || echo "")" \
  "$([ -n "$APPROVE_WHY" ] && printf ', not approved: %s' "$APPROVE_WHY" || echo "")"
if [ "$LANDED" -lt "$BODY_COUNT" ]; then
  note "$((BODY_COUNT - LANDED)) of $BODY_COUNT summary finding(s) did not fit under GitLab's note size limit. Re-run to post them."
fi
