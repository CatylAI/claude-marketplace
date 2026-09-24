#!/usr/bin/env bash
# post-review.sh - post a finished code-review-core review to a GitHub pull request.
#
#   scripts/post-review.sh [--pr <n>] [--repo <owner>/<repo>] [--artifacts <dir>] [--dry-run]
#                          [--no-approve]
#
# Reads <artifacts>/VALIDATED.json (written by code-review-core's `contract.py finalize`), routes
# each finding to an inline review comment or the review body, and submits ONE review whose event
# follows the document's verdict. It decides nothing about the code: no severity is changed, no
# verdict is computed when the document supplies one, and no finding is dropped.
#
# Refusals are the point. A missing or unparseable VALIDATED.json means the review did not finish,
# and a clean review posted over an unfinished run turns "we do not know" into a green check that a
# human will trust. Every such path exits non-zero and posts nothing.
#
# Safety. Findings are untrusted text - an agent reviewing a shell script routinely quotes command
# substitutions, backticks and semicolons. No value from the document is ever interpolated into a
# string the shell re-parses: jq carries every field into a JSON payload, the payload reaches gh
# through a file, and nothing here builds a command string or calls eval. Every rendered string
# also has `<!--` and `-->` broken with a zero-width space, so finding text can neither open an HTML
# comment nor forge one of the hidden markers this script reads back on the next run.
#
# Idempotency. Every posted finding carries a hidden fingerprint marker:
#     <!-- code-review-core:fp2:<P>:<T> -->
# <P> is the path parsed from `location` (verbatim), or the whole location, lowercased with
# whitespace collapsed, when it does not parse. <T> is the title, lowercased with whitespace
# collapsed. Both are URI-encoded, so the key is lossless and ':' cannot occur inside either part.
# Category and line are left out on purpose: `finalize` can change the category between runs (its
# own duplicate check ignores it), and a line moves whenever code above it changes. The finding `id`
# is not used either, because `finalize` renumbers ids on every run.
# Matching is a multiset: N markers with one key mark at most N findings with that key as posted,
# so a second occurrence of the same problem in the same file is still posted.
# Only markers this account posted count; anyone can quote one in a comment of their own.
# The open set. The review body's fourth line lists a digest of the key of every finding in the
# document that wrote it:
#     <!-- code-review-core:active:<d> <d> ... -->   (d = two polynomial hashes of the key, "n.n")
# A marker older than your latest review counts only while that review lists its key (again as a
# multiset), so a finding that was fixed and later comes back is posted again. When the open set
# changes, a review is posted even with no new finding and the same verdict. A review without the
# line (an earlier version) leaves every marker counting.
# Two older forms are still read, so a PR posted by an earlier version gets no duplicates:
#     <!-- code-review-core:fp:<category>~<path>~<title> -->   (slugged; the previous version)
#     <!-- code-review-core:finding:<id> -->                   (first version; honoured only when
#                                                               the same entry carries the finding's
#                                                               title and location)
#
# The verdict. The review body starts with a fixed header whose third line is
#     <!-- code-review-core:verdict:<APPROVE|REQUEST_CHANGES|INCOMPLETE|DERIVED-<event>> -->
# and only that position is read back. The last review of yours that carries it decides whether a
# verdict-only review is needed. When the verdict is not an approval and your standing review on
# the PR is an APPROVE, a COMMENT review would not withdraw it, so that approval is dismissed first.
#
# Portable bash 3.2+ / zsh: no mapfile, no `declare -A`, no ${var^^}. jq 1.6+.
set -euo pipefail

ARTIFACTS=".code-review"
PR_NUMBER=""
REPO=""
DRY_RUN=0
NO_APPROVE=0

# GitHub rejects a comment body over 65,536 characters. The review body is kept under 60,000 so the
# Markdown around it and multi-byte characters have headroom; one inline comment's evidence and
# recommendation are each clipped at 20,000 for the same reason.
MAX_BODY=60000
MAX_FIELD=20000

fail() { # <exit-code> <message...>
  code="$1"; shift
  printf 'post-review: %s\n' "$*" >&2
  exit "$code"
}
note() { printf 'post-review: note: %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
post-review.sh - post a finished code-review-core review to a GitHub pull request.

  --pr <number>           pull request to post to (default: the PR for the current branch)
  --repo <owner>/<repo>   repository (default: resolved from the checkout's origin remote)
  --artifacts <dir>       directory holding VALIDATED.json (default: .code-review)
  --dry-run               print the routing plan and the exact payload; make no gh call at all
  --no-approve            post an APPROVE verdict as a COMMENT review that states the verdict
  -h, --help              this text

Environment:
  CODE_REVIEW_BLOCKING_FLOOR   BLOCKER|MAJOR|MINOR|NIT. Used only when the document carries no
                               verdict (a hand-built document). When VALIDATED.json has a verdict,
                               its `blocking_floor` is the floor, and a disagreeing value here is
                               reported on stderr and otherwise ignored.

Exit status: 0 posted (or nothing new to post). Non-zero means NO review was posted, with the
reason on stderr. 10 means you have an unsubmitted pending review on the pull request. 11 means an
earlier approval of yours could not be dismissed; the message gives the command to run.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr)         [ $# -ge 2 ] || fail 2 "--pr needs a number"; PR_NUMBER="$2"; shift 2 ;;
    --repo)       [ $# -ge 2 ] || fail 2 "--repo needs <owner>/<repo>"; REPO="$2"; shift 2 ;;
    --artifacts)  [ $# -ge 2 ] || fail 2 "--artifacts needs a directory"; ARTIFACTS="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-approve) NO_APPROVE=1; shift ;;
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

# The commit the review was run against. Anchoring comments to it (commit_id) keeps them on the
# lines that were reviewed even if the branch moved since.
REVIEWED_SHA=""
if [ -f "$ARTIFACTS/CONTEXT.json" ]; then
  REVIEWED_SHA="$(jq -r '.reviewed_sha // "" | tostring' "$ARTIFACTS/CONTEXT.json" 2>/dev/null || true)"
  printf '%s' "$REVIEWED_SHA" | grep -Eq '^[0-9a-f]{40}$' || REVIEWED_SHA=""
fi
COMMIT_ID="$REVIEWED_SHA"

# --- what is already on the pull request --------------------------------------------------------
printf '%s' '{"comments": [], "reviews": []}' > "$TMPD/existing.json"
IS_SELF=0
ME=""
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

  gh api "repos/$REPO/pulls/$PR_NUMBER" > "$TMPD/pr.json" 2>"$TMPD/err" \
    && jq -e 'type == "object"' "$TMPD/pr.json" >/dev/null 2>&1 || fail 8 \
    "could not read $REPO#$PR_NUMBER: $(head -c 300 "$TMPD/err"). Nothing was posted."
  PR_AUTHOR="$(jq -r '.user.login // ""' "$TMPD/pr.json")"
  PR_HEAD="$(jq -r '.head.sha // ""' "$TMPD/pr.json")"
  if [ -z "$COMMIT_ID" ]; then
    COMMIT_ID="$PR_HEAD"
  elif [ -n "$PR_HEAD" ] && [ "$PR_HEAD" != "$COMMIT_ID" ]; then
    note "the pull request head ($PR_HEAD) is not the reviewed commit ($COMMIT_ID); inline comments are anchored to the reviewed commit."
  fi

  # GitHub refuses APPROVE and REQUEST_CHANGES from the pull request's own author. A token that
  # cannot read /user (an Actions GITHUB_TOKEN) is never the author of a human's PR, so an unknown
  # login is treated as "not the author". The login also decides which reviews are "yours" below;
  # when it is unknown, any review that starts with this script's header counts as yours.
  ME="$(gh api user --jq '.login' 2>/dev/null || true)"
  if [ -n "$ME" ] && [ "$ME" = "$PR_AUTHOR" ]; then IS_SELF=1; fi

  # Fail closed: a read-back that silently returns nothing makes every finding look new, and the
  # whole review is posted a second time.
  gh api "repos/$REPO/pulls/$PR_NUMBER/comments" --paginate > "$TMPD/comments.json" 2>"$TMPD/err" || fail 8 \
    "could not read the existing review comments on $REPO#$PR_NUMBER, so a post could duplicate them: $(head -c 300 "$TMPD/err"). Nothing was posted."
  gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --paginate > "$TMPD/reviews.json" 2>"$TMPD/err" || fail 8 \
    "could not read the existing reviews on $REPO#$PR_NUMBER, so a post could duplicate them: $(head -c 300 "$TMPD/err"). Nothing was posted."
  # --paginate prints one JSON array per page; --slurpfile collects them.
  jq -n --slurpfile c "$TMPD/comments.json" --slurpfile r "$TMPD/reviews.json" '
      { comments: [$c[][]? | { body: (.body // "" | tostring), path: (.path // null),
                                user: (.user.login // ""), rid: (.pull_request_review_id // 0) }],
        reviews:  [$r[][]? | { id, state, body: (.body // "" | tostring), user: (.user.login // "") }] }' \
    > "$TMPD/existing.json" 2>/dev/null || fail 8 \
    "the existing comments or reviews on $REPO#$PR_NUMBER did not parse as JSON, so a post could duplicate them. Nothing was posted."

  # GitHub allows one pending (unsubmitted) review per user per pull request, and creating a second
  # fails. Only the owner can see a pending review, so any one listed here is yours.
  PENDING_ID="$(jq -r '[.reviews[] | select(.state == "PENDING") | .id] | first // ""' "$TMPD/existing.json")"
  if [ -n "$PENDING_ID" ]; then
    fail 10 "you have an unsubmitted pending review ($PENDING_ID) on $REPO#$PR_NUMBER, and GitHub allows only one. Submit it in the web UI or delete it with: gh api --method DELETE repos/$REPO/pulls/$PR_NUMBER/reviews/$PENDING_ID - then re-run. Nothing was posted."
  fi
fi

# --- routing, body and payload, computed entirely inside jq ---------------------------------------
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
# Fingerprint (see the header). @uri leaves !*'() alone in jq 1.6 and encodes them in 1.7, so they are
# encoded explicitly: the same finding must give the same key whichever jq wrote it.
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

($ex[0] // {comments: [], reviews: []}) as $E
# Only what this account posted counts: anyone can quote a marker in a comment of their own. When
# the login is unknown (a token that cannot read /user), everything is read. A comment's `rid` is
# the review it was posted with.
| ([ ($E.comments[] | select($me == "" or .user == $me) | {rid, body, path}),
     ($E.reviews[]  | select($me == "" or .user == $me) | {rid: .id, body, path: null}) ]) as $mine
# Your reviews: by login when it is known, else by this script's header.
| def ours: (.body | startswith("## Code review"));
  ([$E.reviews[] | select(if $me != "" then .user == $me else ours end)
                 | select(.state != "DISMISSED" and .state != "PENDING")]) as $live
| ([$live[] | select(ours)] | last | if . == null then null else . + {rid: .id} end) as $lastown
| (if $lastown == null then null
   else ([$lastown.body | capture("^## Code review\n\n<!-- code-review-core:verdict:(?<v>[A-Z_-]+) -->(\n|$)") | .v] | first) as $nv
      | ([$lastown.body | capture("<!-- code-review-core:finding:verdict-(?<v>[A-Z_-]+) -->\\s*$") | .v] | first) as $lv
      | if $nv != null then {kind: "verdict", v: $nv}
        elif $lv != null then {kind: "verdict", v: $lv}
        else {kind: "event",
              v: ({"APPROVED": "APPROVE", "CHANGES_REQUESTED": "REQUEST_CHANGES",
                   "COMMENTED": "COMMENT"}[$lastown.state // ""] // "")} end
   end) as $last
# GitHub counts a reviewer's latest APPROVED or CHANGES_REQUESTED review; a later COMMENT does not
# replace it. That standing state is what a non-approval verdict has to withdraw.
| ([$live[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | last) as $standing
# The open set: the fp2 keys of every finding in the document that wrote your latest review. A
# marker older than that review counts only while its key is still open, so a finding that was
# fixed and later comes back is posted again. Markers newer than it (a run whose review did not
# post) always count. null when that review predates the open set.
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
     | ($doc.findings[$k] + { _loc: $r._loc,
                              _fp: ($r | fingerprint),
                              _dg: ($r | fingerprint | digest),
                              _lfp: ($r | legacy_fingerprint),
                              _t: (($r.title // "") | oneline),
                              _l: (($r.location // "n/a") | oneline) }) ]) as $all
| (if   $verdict == "REQUEST_CHANGES" then "REQUEST_CHANGES"
   elif $verdict == "APPROVE"         then "APPROVE"
   elif $verdict == "INCOMPLETE"      then "COMMENT"
   elif ($all | any(blocks($flr)))    then "REQUEST_CHANGES"
   else "COMMENT" end) as $raw_event
| (if $verdict == "" then "DERIVED-" + $raw_event else $verdict end) as $vkey
| (if $raw_event == "COMMENT" then {event: "COMMENT", why: null}
   elif $self then {event: "COMMENT",
                    why: "GitHub does not let an account approve or request changes on its own pull request"}
   elif ($raw_event == "APPROVE") and $noapprove then {event: "COMMENT", why: "--no-approve was passed"}
   else {event: $raw_event, why: null} end) as $ev
| (if ($standing != null) and ($standing.state == "APPROVED")
      and ($ev.event == "COMMENT") and ($raw_event != "APPROVE")
   then [$live[] | select(.state == "APPROVED") | .id] else [] end) as $dismiss
| (($last != null) and ((($last.kind == "verdict") and ($last.v == $vkey))
                        or (($last.kind == "event") and ($last.v == $ev.event)))) as $same_verdict
# Multiset match: each marker accounts for one finding, newest form first. A marker newer than your
# latest review counts outright; an older one also needs its key open in that review.
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
# A review is also needed when the open set changed, or when it was never recorded and a posted
# finding is gone, so the next run knows that finding is closed.
| (if $active != null then ($active | sort) != $keys
   else ([$m.c2.f[], $m.c2.s[], $m.c1.f[], $m.c1.s[]] | any(. > 0)) end) as $set_changed
| (if $active == null then 0
   else (($keys | counts) as $kc | [($active | counts) | to_entries[] | .value - ($kc[.key] // 0) | select(. > 0)] | add // 0) end) as $gone
| ($ann | map(select(._posted | not))) as $new
| ($ann | map(select(._posted))) as $dup
| ($new | map(select((.in_diff == true) and (._loc != null)))) as $inline
| ($new | map(select((.in_diff != true) or  (._loc == null)))) as $bodyf
| ((($new | length) > 0) or ($same_verdict | not) or $set_changed) as $post_needed
| (if $verdict != "" then (($doc.blocking_reason_ids // []) | map(tostring))
   else ($all | map(select(blocks($flr) or escalates($flr))) | map(.id // "?")) end) as $reason_ids
| ($reason_ids | map(. as $i | (($all | map(select(.id == $i)) | first) // {id: $i, _missing: true}))) as $reasons
| ($doc.incomplete_inputs // []) as $incomplete
| (($doc.coverage_notes // []) | map(oneline | clip(500))) as $cov
| (($doc.decision_errors // []) | map("- `\(.source_id // "?")`: \(.error // "" | oneline | clip(500))")) as $derr
| def mkbody($inl; $bod; $moved; $compact):
    [ "## Code review", "", vmark($vkey), amark($keys), "",
      (if $verdict == ""
       then "No `verdict` in the document - event derived at floor `\($fl)`: `\($raw_event)`."
       else "Verdict: **\($verdict)**" + (if $fl == "" then "" else " (blocking floor `\($fl)`)" end)
            + " - review event `\($ev.event)`." end),
      "" ]
    + (if $ev.why != null then
         [ "**Posted as a comment, not as \($raw_event):** \($ev.why). The verdict above stands.", "" ]
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
    + (if ($inl | length) > 0 then [ "\($inl | length) finding(s) are attached inline to the lines they cite.", "" ] else [] end)
    + section("### Pre-existing - not introduced by this diff";
              "These keep their severity; being out of scope is what stops them blocking.";
              ($bod | map(select(.in_diff != true))); $compact)
    + section("### Could not be placed on a line";
              "These cite this diff, but their `location` did not parse into a path and a line.";
              ($bod | map(select(.in_diff == true))); $compact)
    + section("### Could not be anchored inline";
              "GitHub rejected these as inline comments (the cited line is not in the diff GitHub has), so they are listed here.";
              $moved; $compact)
    + (if ($dup | length) > 0 then [ "_\($dup | length) finding(s) already present on this pull request were skipped._", "" ] else [] end)
    + (if $gone > 0 then [ "_\($gone) finding(s) reported by the previous review are no longer reported._", "" ] else [] end)
    + (if ($cov | length) > 0 then [ "### Coverage notes", "" ] + ($cov | map("- " + .)) + [ "" ] else [] end)
    + (if ($derr | length) > 0 then [ "### Validator decision errors", "" ] + $derr + [ "" ] else [] end)
    | join("\n");
  # Over the cap even when compact: cut at the last whole entry, so no finding is half-shown and
  # every finding that is shown has its marker. The ones cut off are posted by the next run.
  def fitbody($inl; $bod; $moved):
    mkbody($inl; $bod; $moved; false) as $b
    | if ($b | length) <= $maxbody then $b
      else mkbody($inl; $bod; $moved; true) as $c
      | if ($c | length) <= $maxbody then $c
        else ($c[0:($maxbody - 300)]) as $cut
          | ($cut | rindex("\n- **")) as $at
          | (if $at == null then $cut else $cut[0:$at] end)
            + "\n\n_Body truncated to fit GitHub's comment size limit. The findings cut off here are posted by the next run._"
        end
      end;

  (($inline | map("inline  \(._loc.p):\(._loc.n)  [\(sev)] \(.id // "?") \((.title // "") | oneline)"))
   + ($bodyf | map("body    [\(sev)] \(.id // "?") \((.title // "") | oneline)  (reason: "
                   + (if .in_diff != true then "in_diff=false" else "location did not parse" end) + ")"))
   + ($dup   | map("skip    \(.id // "?") already posted"))
   + (if ($same_verdict | not) and (($new | length) == 0)
      then [ "body    verdict-only review (\($vkey); your last review from this pipeline said \($last.v // "nothing"))" ]
      elif $same_verdict and (($new | length) == 0) and $set_changed
      then [ "body    review for the changed set of open findings (\($gone) no longer reported)" ]
      else [] end)
   + ($dismiss | map("dismiss review \(.) (your standing APPROVE; the verdict is now \($vkey))"))
  ) as $plan
| fitbody($inline; $bodyf; []) as $body
| fitbody([]; $bodyf; $inline) as $fbody
| { event: $ev.event,
    raw_event: $raw_event,
    downgrade: $ev.why,
    verdict: $verdict,
    vkey: $vkey,
    floor: $fl,
    plan: $plan,
    post_needed: $post_needed,
    dismiss: $dismiss,
    new_count: ($new | length),
    dup_count: ($dup | length),
    inline_count: ($inline | length),
    body_count: ($bodyf | length),
    body_landed: ($body | landed),
    fallback_landed: ($fbody | landed),
    payload: ({ body: $body, event: $ev.event }
              + (if ($inline | length) > 0
                 then { comments: ($inline | map({ path: ._loc.p,
                                                   line: (._loc.n | tonumber),
                                                   side: "RIGHT",
                                                   body: inlinebody })) }
                      + (if $commit == "" then {} else { commit_id: $commit } end)
                 else {} end)),
    fallback: { body: $fbody, event: $ev.event } }
JQPROG
)"

RESULT_FILE="$TMPD/result.json"
jq --slurpfile ex "$TMPD/existing.json" --arg floor "$FLOOR" --arg commit "$COMMIT_ID" --arg me "$ME" \
   --argjson self "$([ "$IS_SELF" -eq 1 ] && echo true || echo false)" \
   --argjson noapprove "$([ "$NO_APPROVE" -eq 1 ] && echo true || echo false)" \
   --argjson maxbody "$MAX_BODY" --argjson maxfield "$MAX_FIELD" \
   "$JQ_PROG" "$VALIDATED" > "$RESULT_FILE" || fail 5 \
  "could not route the findings in $VALIDATED - the document does not match the agent contract. Nothing was posted."
[ -s "$RESULT_FILE" ] || fail 5 "routing produced no output for $VALIDATED. Nothing was posted."

EVENT="$(jq -r '.event' "$RESULT_FILE")"
VKEY="$(jq -r '.vkey' "$RESULT_FILE")"
DOWNGRADE="$(jq -r '.downgrade // ""' "$RESULT_FILE")"
POST_NEEDED="$(jq -r '.post_needed' "$RESULT_FILE")"
DUP_COUNT="$(jq -r '.dup_count' "$RESULT_FILE")"
INLINE_COUNT="$(jq -r '.inline_count' "$RESULT_FILE")"
BODY_COUNT="$(jq -r '.body_count' "$RESULT_FILE")"
PLAN="$(jq -r '.plan[]?' "$RESULT_FILE")"
DISMISS_COUNT="$(jq -r '.dismiss | length' "$RESULT_FILE")"

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
  printf '  blocking floor: %s\n' "${FLOOR:-(not recorded in the document)}"
  printf '  verdict:        %s\n' "${DOC_VERDICT:-(absent, derived)}"
  printf '  review event:   %s%s\n' "$EVENT" "${DOWNGRADE:+ (downgraded: $DOWNGRADE)}"
  printf '  commit:         %s\n' "${COMMIT_ID:-(the pull request head at post time)}"
  printf '  routing:        %s inline, %s in body, %s skipped\n' "$INLINE_COUNT" "$BODY_COUNT" "$DUP_COUNT"
  printf '  note:           a dry run cannot see what is already on the PR, who authored it, or an approval to dismiss\n'
  printf '\nplan:\n'
  if [ -n "$PLAN" ]; then printf '%s\n' "$PLAN" | sed 's/^/  /'; else printf '  (nothing to post)\n'; fi
  printf '\npayload:\n'
  jq '.payload' "$RESULT_FILE"
  exit 0
fi

# --- withdraw a standing approval ------------------------------------------------------------------
# A COMMENT review does not replace an earlier APPROVE, so without this an INCOMPLETE run would leave
# the green approval in place. It runs before the post: if the post then fails, the PR is left with
# no approval rather than a stale one. REST: PUT .../reviews/{id}/dismissals. On a protected branch
# only an admin, or someone on the branch's dismissal list, may dismiss; that failure stops here.
# Indexed rather than `for rid in $ids`: zsh does not word-split an unquoted variable.
DISMISSED=0
while [ "$DISMISSED" -lt "$DISMISS_COUNT" ]; do
  rid="$(jq -r --argjson i "$DISMISSED" '.dismiss[$i] | tostring' "$RESULT_FILE")"
  case "$rid" in ""|*[!0-9]*) fail 11 "unexpected review id '$rid' to dismiss. No review was posted." ;; esac
  msg="Superseded by a newer code-review-core verdict ($VKEY), which is not an approval."
  if ! gh api --method PUT "repos/$REPO/pulls/$PR_NUMBER/reviews/$rid/dismissals" \
       -f message="$msg" -f event=DISMISS > /dev/null 2>"$TMPD/err"; then
    fail 11 "could not dismiss your earlier approval (review $rid) on $REPO#$PR_NUMBER: $(head -c 300 "$TMPD/err" | tr '\n' ' '). The verdict is now $VKEY, and a comment would leave that approval standing. Dismissing needs write access, and on a protected branch an admin or someone allowed to dismiss reviews. Run: gh api --method PUT repos/$REPO/pulls/$PR_NUMBER/reviews/$rid/dismissals -f message='$msg' -f event=DISMISS - then re-run. $DISMISSED earlier approval(s) were dismissed; no review was posted."
  fi
  DISMISSED=$((DISMISSED + 1))
done
[ "$DISMISSED" -eq 0 ] || note "dismissed $DISMISSED earlier approval(s): the verdict is now $VKEY."

if [ "$POST_NEEDED" != "true" ]; then
  printf 'post-review: every finding and the verdict are already on %s#%s - nothing new to post (%s skipped).\n' \
    "$REPO" "$PR_NUMBER" "$DUP_COUNT"
  exit 0
fi

# --- post, as one atomic review -------------------------------------------------------------------
# One API call, not `gh pr review` plus a loop of comment posts: either the whole review lands or
# none of it does, so a rejected inline comment cannot leave half a review on the pull request.
post_payload() { # <payload-file> -> gh's stdout in $TMPD/response.json, stderr in $TMPD/err
  gh api --method POST \
    -H "Accept: application/vnd.github+json" \
    "repos/$REPO/pulls/$PR_NUMBER/reviews" \
    --input "$1" > "$TMPD/response.json" 2>"$TMPD/err"
}

jq '.payload' "$RESULT_FILE" > "$TMPD/payload.json"
FALLBACK_USED=0
if ! post_payload "$TMPD/payload.json"; then
  # A 422 with inline comments almost always means one cited line is not in the diff GitHub has
  # (a context line, or a commit GitHub does not know). Retry once with every inline finding moved
  # into the body, so the review still lands and nothing is dropped.
  if [ "$INLINE_COUNT" -gt 0 ] && grep -q 'HTTP 422' "$TMPD/err"; then
    note "GitHub rejected the inline comments ($(head -c 300 "$TMPD/err" | tr '\n' ' ')); retrying with every finding in the review body."
    jq '.fallback' "$RESULT_FILE" > "$TMPD/fallback.json"
    post_payload "$TMPD/fallback.json" || fail 8 \
      "gh refused the review for $REPO#$PR_NUMBER even without inline comments: $(head -c 500 "$TMPD/err"). Nothing was posted."
    FALLBACK_USED=1
  else
    fail 8 "gh refused the review payload for $REPO#$PR_NUMBER: $(head -c 500 "$TMPD/err"). Nothing was posted."
  fi
fi

# Report what landed, counted from the markers in the body that was sent, not from the plan: a body
# cut to fit the size limit carries fewer findings than were routed to it.
URL="$(jq -r '.html_url // ""' "$TMPD/response.json" 2>/dev/null || true)"
if [ "$FALLBACK_USED" -eq 1 ]; then
  WANTED=$((BODY_COUNT + INLINE_COUNT))
  LANDED="$(jq -r '.fallback_landed' "$RESULT_FILE")"
  printf 'post-review: posted %s to %s#%s - 0 inline (%s moved to the body after a 422), %s in body, %s skipped as already present. %s\n' \
    "$EVENT" "$REPO" "$PR_NUMBER" "$INLINE_COUNT" "$LANDED" "$DUP_COUNT" "$URL"
else
  WANTED="$BODY_COUNT"
  LANDED="$(jq -r '.body_landed' "$RESULT_FILE")"
  printf 'post-review: posted %s to %s#%s - %s inline, %s in body, %s skipped as already present. %s\n' \
    "$EVENT" "$REPO" "$PR_NUMBER" "$INLINE_COUNT" "$LANDED" "$DUP_COUNT" "$URL"
fi
if [ "$LANDED" -lt "$WANTED" ]; then
  note "$((WANTED - LANDED)) of $WANTED body finding(s) did not fit under GitHub's size limit. Re-run to post them."
fi
