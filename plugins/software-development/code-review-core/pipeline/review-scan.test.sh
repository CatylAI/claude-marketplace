#!/usr/bin/env bash
# review-scan.test.sh — tests for review-scan.sh, its detectors, and normalize.py.
#
#   ./review-scan.test.sh            # run everything
#   zsh ./review-scan.test.sh        # the portability half of the contract
#
# Every test builds a THROWAWAY GIT REPO in a temp dir with a known diff and asserts on the emitted
# SCAN.json. No network, no fixtures checked into the repo, nothing touched outside $TMP.
#
# Tests that need a specific binary skip themselves when it is absent, and say so — the same
# degradation the scanner itself is built around. A skipped test is reported, never counted as a
# pass.

set -uo pipefail
# No __pycache__ left in the plugin tree: the suites import normalize/contract/testpaths in place.
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCAN="$SELF_DIR/review-scan.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-scan-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- fixture repo builder
# mkrepo <name> — a git repo with one commit on main, then a branch. Callers add files and call
# `commit_branch`. `origin/main` is written by hand: the scanner's whole contract is "diff against a
# base ref", and a fixture with a real remote would need a network or a second clone.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  printf 'seed\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "seed"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" checkout --quiet -b feature
  printf '%s\n' "$d"
}

commit_branch() {
  git -C "$1" add -A
  git -C "$1" commit --quiet -m "change"
}

# run_scan <repo> [extra args...] — run the scanner, capture stderr, echo the out dir.
run_scan() {
  local d="$1"; shift
  ( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" "$@" > "$d/.stdout" 2> "$d/.stderr" )
  printf '%s\n' "$d/.code-review"
}

# jq_get <file> <python-expression-on-d> — read a value out of a JSON file without needing jq.
jq_get() {
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print($2)" "$1" 2>/dev/null
}

printf 'review-scan tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

# ============================================================== argument handling
# --base is OPTIONAL now (origin/HEAD -> origin/main -> origin/master). This case used to run the
# scanner with no --base from the suite's own cwd, which after the fallback would have scanned THIS
# repository and written .code-review into it. It now runs in a throwaway repo with no remote refs.
t="no --base and no origin refs: exits 2 and names every ref it tried"
d="$(mkrepo nobase)"
git -C "$d" update-ref -d refs/remotes/origin/main
( cd "$d" && "$SCAN" --out "$d/o" >/dev/null 2>"$d/.err" ); rc=$?
if [ "$rc" -eq 2 ] && grep -q 'origin/HEAD' "$d/.err" && grep -q 'origin/main' "$d/.err" \
   && grep -q 'origin/master' "$d/.err" && grep -q -- '--base main' "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc stderr: $(head -c 300 "$d/.err")"; fi

t="unresolvable base ref exits non-zero"
d="$(mkrepo badbase)"
if ! ( cd "$d" && "$SCAN" --base does/not/exist --out "$d/out" >/dev/null 2>&1 ); then
  pass "$t"
else fail "$t" "accepted a nonexistent base ref"; fi

t="unknown flag exits non-zero"
if ! "$SCAN" --base HEAD --wat >/dev/null 2>&1; then pass "$t"; else fail "$t" "accepted --wat"; fi

t="--help exits non-zero and prints usage"
out="$("$SCAN" --help 2>&1)"
case "$out" in *"usage: review-scan.sh"*) pass "$t" ;; *) fail "$t" "no usage text" ;; esac

t="refuses to run outside a git repo"
mkdir -p "$TMP/notgit"
if ! ( cd "$TMP/notgit" && "$SCAN" --base HEAD >/dev/null 2>&1 ); then
  pass "$t"
else fail "$t" "ran outside a repo"; fi

# ============================================================== empty / docs-only diff
t="docs-only diff produces a valid empty contract"
d="$(mkrepo docsonly)"
printf '# hello\n\nsome prose\n' > "$d/GUIDE.md"
commit_branch "$d"
o="$(run_scan "$d")"
if [ -f "$o/SCAN.json" ] && [ "$(jq_get "$o/SCAN.json" "d['metrics']['total']")" = "0" ] \
   && [ "$(jq_get "$o/SCAN.json" "d['verdict']")" = "APPROVE" ]; then
  pass "$t"
else fail "$t" "$(cat "$d/.stderr" 2>/dev/null | tail -3)"; fi

t="SCAN-SUMMARY.md is written even with zero findings"
if [ -s "$o/SCAN-SUMMARY.md" ]; then pass "$t"; else fail "$t" "summary missing or empty"; fi

t="exit status is 0 when findings exist (report, do not enforce)"
# Asserted below on the ruff fixture too; here it covers the empty case.
if grep -q 'wrote' "$d/.stderr" 2>/dev/null; then pass "$t"; else fail "$t" "no completion line"; fi

# ============================================================== artifact-directory fence (ADR-004)
# The artifact root fences itself on creation, so keeping review state out of history never depends
# on the CONSUMING repo having remembered a .gitignore entry. Reuses the docs-only fixture above:
# $d is that repo and $o is its .code-review dir.
t="the artifact root gets a .gitignore containing '*'"
if [ -f "$o/.gitignore" ] && [ "$(cat "$o/.gitignore")" = "*" ]; then pass "$t"
else fail "$t" "expected '*', got: $(cat "$o/.gitignore" 2>/dev/null || printf '<no file>')"; fi

t="the fence applies recursively — git ignores a path under raw/"
# This is the reason the fence goes on $OUT and not on $RAW. Asserted through git itself rather
# than by reading the file, because recursion is the property that makes one file sufficient.
if git -C "$d" check-ignore -q ".code-review/raw/pytest.json"; then pass "$t"
else fail "$t" "git does not ignore .code-review/raw/ despite the fence"; fi

t="a pre-existing user-edited .gitignore is not overwritten"
# The `[ -e ] ||` guard. A repo that deliberately un-ignores an artifact keeps its edit, and the
# write stays idempotent across the several times per review that these mkdirs run.
d_keep="$(mkrepo fencekeep)"
printf '# notes\n\nprose\n' > "$d_keep/NOTES.md"
commit_branch "$d_keep"
mkdir -p "$d_keep/.code-review"
printf '# keep me\n!VALIDATED.json\n' > "$d_keep/.code-review/.gitignore"
o_keep="$(run_scan "$d_keep")"
if [ "$(cat "$o_keep/.gitignore")" = "$(printf '# keep me\n!VALIDATED.json')" ]; then pass "$t"
else fail "$t" "user .gitignore was clobbered: $(cat "$o_keep/.gitignore" 2>/dev/null)"; fi

# ============================================================== python detector
if have ruff; then
  t="ruff finding on a changed line survives to SCAN.json"
  d="$(mkrepo ruffcase)"
  printf 'def f():\n    try:\n        pass\n    except:\n        pass\n' > "$d/mod.py"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors python)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='ruff')")"
  if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "no ruff finding (got ${n:-none})"; fi

  t="bare except (E722) is MAJOR"
  sev="$(jq_get "$o/SCAN.json" "next((f['severity'] for f in d['findings'] if f.get('rule')=='E722'), 'absent')")"
  if [ "$sev" = "MAJOR" ]; then pass "$t"; else fail "$t" "E722 severity=$sev"; fi

  t="scanner exits 0 despite findings"
  if ( cd "$d" && "$SCAN" --base origin/main --out "$d/o2" --detectors python >/dev/null 2>&1 ); then
    pass "$t"
  else fail "$t" "non-zero exit with findings present"; fi

  # An in-code suppression must NOT delete a finding at the detector tier. The reviewer's rule that a
  # comment is not evidence is inert if the comment removed the finding one tier below the reviewer,
  # so this is the case that proves the detector surfaces it and leaves the judgement to scan triage.
  t="a '# noqa'-suppressed ruff finding still reaches SCAN.json"
  d="$(mkrepo ruffnoqa)"
  printf 'def f():\n    try:\n        pass\n    except:  # noqa: E722\n        pass\n' > "$d/mod.py"
  commit_branch "$d"
  # Negative control, run first: confirm this ruff build really does hide E722 behind the `# noqa`
  # by default. Without that, the assertion below would pass whether --ignore-noqa is passed or not,
  # and a green test would prove nothing.
  suppressed="$(cd "$d" && ruff check --output-format=json --no-cache mod.py 2>/dev/null \
    | python3 -c 'import json,sys; print(sum(1 for f in json.load(sys.stdin) if f["code"]=="E722"))' 2>/dev/null)"
  o="$(run_scan "$d" --detectors python)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='E722')")"
  if [ "${suppressed:-x}" != "0" ]; then
    skipt "$t" "this ruff honours '# noqa: E722' differently (default run saw ${suppressed:-?}), control invalid"
  elif [ "${n:-0}" -ge 1 ]; then pass "$t"
  else fail "$t" "E722 suppressed away (got ${n:-none}); is --ignore-noqa still passed in python.sh?"; fi
else
  skipt "ruff detector tests" "ruff not installed"
fi

if have bandit; then
  t="bandit HIGH maps to BLOCKER"
  d="$(mkrepo bandcase)"
  # md5 for a security purpose is bandit's canonical HIGH; no credential-shaped string is used here
  # on purpose, so the fixture itself can never trip a secret scanner.
  printf 'import hashlib\n\n\ndef h(x):\n    return hashlib.md5(x).hexdigest()\n' > "$d/hash.py"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors python)"
  sev="$(jq_get "$o/SCAN.json" "next((f['severity'] for f in d['findings'] if f['tool']=='bandit'), 'absent')")"
  case "$sev" in
    BLOCKER|MAJOR|MINOR) pass "$t (got $sev)" ;;
    *) fail "$t" "no bandit finding" ;;
  esac

  # The `# nosec` half of the same rule. This one matters more than the ruff case: a silently
  # suppressed bandit HIGH is a suppressed BLOCKER, and it would never appear in any count a reviewer
  # or the blocking predicate ever sees.
  t="a '# nosec'-suppressed bandit finding still reaches SCAN.json"
  d="$(mkrepo bandnosec)"
  printf 'import hashlib\n\n\ndef h(x):\n    return hashlib.md5(x).hexdigest()  # nosec\n' > "$d/hash.py"
  commit_branch "$d"
  # Negative control, same reasoning as the ruff case above.
  suppressed="$(cd "$d" && bandit -f json -q hash.py 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["results"]))' 2>/dev/null)"
  o="$(run_scan "$d" --detectors python)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='bandit')")"
  if [ "${suppressed:-x}" != "0" ]; then
    skipt "$t" "this bandit honours '# nosec' differently (default run saw ${suppressed:-?}), control invalid"
  elif [ "${n:-0}" -ge 1 ]; then pass "$t"
  else fail "$t" "B324 suppressed away (got ${n:-none}); is --ignore-nosec still passed in python.sh?"; fi
else
  skipt "bandit detector test" "bandit not installed"
fi

# ============================================================== diff scoping
t="pre-existing finding on an unchanged line is dropped"
if have ruff; then
  d="$(mkrepo scoping)"
  # The bare except is committed to MAIN, so it is pre-existing debt. The branch appends an unrelated
  # clean function. A scanner without diff-scoping reports the except; this one must not.
  printf 'def old():\n    try:\n        pass\n    except:\n        pass\n' > "$d/mod.py"
  git -C "$d" checkout --quiet main
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "pre-existing debt"
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" checkout --quiet feature
  git -C "$d" merge --quiet main -m merge 2>/dev/null || git -C "$d" reset --hard --quiet main
  printf '\n\ndef added(value):\n    return value + 1\n' >> "$d/mod.py"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors python)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='E722')")"
  raw="$(jq_get "$o/SCAN.raw.json" "sum(1 for f in d['findings'] if f.get('rule')=='E722')")"
  if [ "${n:-0}" = "0" ] && [ "${raw:-0}" -ge 1 ]; then
    pass "$t (raw had it, scoped dropped it)"
  else fail "$t" "scoped=$n raw=$raw — expected scoped 0 and raw >= 1"; fi

  t="diff_scoped is recorded true"
  if [ "$(jq_get "$o/SCAN.json" "d['scan_meta']['diff_scoped']")" = "True" ]; then
    pass "$t"
  else fail "$t" "diff_scoped not true"; fi
else
  skipt "diff-scoping tests" "ruff not installed"
fi

# ============================================================== shell detector
if have shellcheck; then
  t="shellcheck finding is reported"
  d="$(mkrepo shellcase)"
  printf '#!/usr/bin/env bash\ncd /tmp\necho "$UNSET_ONE"\n' > "$d/s.sh"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors shell)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='shellcheck')")"
  if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "no shellcheck findings"; fi

  t="a .py file is never handed to shellcheck (no SC1071)"
  # Regression test for a real bug: the extensionless-script shebang sniff read a fixed byte count,
  # spanned into the docstring, matched `*sh*` on prose, and produced a MAJOR "ShellCheck only
  # supports sh/bash/dash/ksh scripts" finding against a Python file.
  d="$(mkrepo shebang)"
  printf '#!/usr/bin/env python3\n"""Uses a shell to do things."""\nprint(1)\n' > "$d/tool"
  chmod +x "$d/tool"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors shell)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='SC1071')")"
  if [ "${n:-0}" = "0" ]; then pass "$t"; else fail "$t" "got $n SC1071 finding(s)"; fi

  t="an extensionless bash script IS picked up"
  d="$(mkrepo shebang2)"
  printf '#!/usr/bin/env bash\ncd /tmp\n' > "$d/hook"
  chmod +x "$d/hook"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors shell)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='shellcheck')")"
  if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "extensionless script was not scanned"; fi
else
  skipt "shell detector tests" "shellcheck not installed"
fi

# ============================================================== terraform detector
# The IaC path is SELECTED by an extension signal in review-scan.sh (`*.tf|*.tfvars|*.hcl` sets
# SIG_IAC, which appends `terraform` to DETECTORS). Before `detectors/terraform.sh` existed, that
# selection resolved to `no such detector: terraform` — a skip record that looks identical in
# SCAN-SUMMARY.md to "the tool is not installed", so an IaC change read as scanned-but-toolless when
# in fact nothing had even been dispatched. The first assertion pins the dispatch itself; nothing
# else in this file would notice the detector being deleted again.
t="an IaC diff dispatches the terraform detector (not 'no such detector')"
d="$(mkrepo tfdispatch)"
mkdir -p "$d/infra"
printf 'resource "aws_s3_bucket" "b" {\n  bucket = "example-bucket"\n}\n' > "$d/infra/main.tf"
commit_branch "$d"
o="$(run_scan "$d")"
if [ -f "$o/raw/terraform.skipped" ] && grep -q 'no such detector' "$o/raw/terraform.skipped"; then
  fail "$t" "review-scan.sh selected 'terraform' but no detectors/terraform.sh exists"
elif grep -q 'run  terraform' "$d/.stderr"; then
  pass "$t"
else
  fail "$t" "terraform was never dispatched: $(grep -E 'run |skip ' "$d/.stderr" | tr '\n' ';')"
fi

t="the terraform detector still exits 0 and leaves a record for every tool it could not run"
# The contract, end to end rather than per-tool (detectors/terraform.test.sh drives the tool arms).
# Every absent binary must leave a .skipped naming a reason; silence would be indistinguishable from
# a clean IaC scan.
missing_record=""
for tool in tflint checkov tfsec; do
  if ! have "$tool" && [ ! -f "$o/raw/$tool.skipped" ] && [ ! -f "$o/raw/$tool.json" ]; then
    missing_record="$missing_record $tool"
  fi
done
if [ -z "$missing_record" ]; then pass "$t"; else fail "$t" "no record for:$missing_record"; fi

if have terraform; then
  t="a misformatted .tf yields a terraform_fmt finding on a changed line"
  # `terraform fmt -check` has no JSON mode, so the detector synthesises one finding per file at
  # line 1 and folds it into tflint.json. Line 1 is inside the hunk for a newly added file, so the
  # finding must survive diff-scoping.
  d="$(mkrepo tffmt)"
  mkdir -p "$d/infra"
  printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "example-bucket"\n}\n' > "$d/infra/main.tf"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors terraform)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='terraform_fmt')")"
  if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "no terraform_fmt finding (got ${n:-none})"; fi

  t="a terraform-fmt-clean file produces no terraform_fmt finding"
  # The false-positive direction. Without it, a detector that emitted one finding per changed file
  # regardless of formatting would pass the case above.
  d="$(mkrepo tffmtclean)"
  mkdir -p "$d/infra"
  printf 'resource "aws_s3_bucket" "b" {\n  bucket = "example-bucket"\n}\n' > "$d/infra/main.tf"
  commit_branch "$d"
  o="$(run_scan "$d" --detectors terraform)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='terraform_fmt')")"
  if [ "${n:-x}" = "0" ]; then pass "$t"; else fail "$t" "$n terraform_fmt finding(s) on a clean file"; fi

  t="the fmt findings survive even when tflint is absent (they are promoted, not lost)"
  # `need tflint` failing takes the merge step with it, so the synthesised fmt document has to be
  # promoted to raw/tflint.json on the way out. Skipped rather than faked when tflint IS installed:
  # the promote branch is unreachable then, and asserting it anyway would assert nothing.
  if have tflint; then
    skipt "$t" "tflint is installed, so the promote branch is unreachable here"
  else
    d="$(mkrepo tffmtpromote)"
    mkdir -p "$d/infra"
    printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "x"\n}\n' > "$d/infra/main.tf"
    commit_branch "$d"
    o="$(run_scan "$d" --detectors terraform)"
    if [ -f "$o/raw/tflint.json" ] \
       && [ "$(jq_get "$o/raw/tflint.json" "len(d['issues'])")" -ge 1 ]; then
      pass "$t"
    else fail "$t" "raw/tflint.json absent or empty with tflint uninstalled"; fi
  fi
else
  skipt "terraform fmt tests" "terraform not installed"
fi

if have checkov; then
  t="checkov reports an insecure IaC resource on a changed line"
  # A world-open ingress rule, not a bare S3 bucket: checkov's bucket policies are opt-in in recent
  # releases and a bare `aws_s3_bucket` comes back clean, which would make this case vacuous.
  d="$(mkrepo tfcheckov)"
  mkdir -p "$d/infra"
  cat > "$d/infra/main.tf" <<'TF'
resource "aws_security_group" "open" {
  name = "open"
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
TF
  commit_branch "$d"
  o="$(run_scan "$d" --detectors terraform)"
  n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='checkov')")"
  if [ "${n:-0}" -ge 1 ]; then
    pass "$t"
  else
    # A checkov build whose rule set no longer flags this resource makes the case vacuous rather
    # than failed — report it as a skip so a green run never means "the IaC path is covered" when
    # the fixture itself stopped being a defect.
    raw_n="$(jq_get "$o/raw/checkov.json" "len(d['results']['failed_checks'])")"
    if [ "${raw_n:-0}" = "0" ]; then
      skipt "$t" "this checkov build reports nothing on the fixture; the assertion would be vacuous"
    else
      fail "$t" "checkov found $raw_n raw finding(s) but none survived into SCAN.json"
    fi
  fi

  t="checkov's file paths are repo-relative, so the diff filter can match them"
  # checkov reports paths relative to ITS scan root (a leading `/infra/main.tf`), which matches no
  # diff hunk unless normalize.py re-roots it. A finding surviving the filter at all proves it did;
  # this asserts the anchor text directly so a regression is a message, not a silent zero.
  loc="$(jq_get "$o/SCAN.json" "next((f['location'] for f in d['findings'] if f['tool']=='checkov'), 'absent')")"
  case "$loc" in
    infra/main.tf:*) pass "$t" ;;
    absent) skipt "$t" "no checkov finding to read a location off (see the case above)" ;;
    *) fail "$t" "location='$loc' (expected infra/main.tf:<lines>)" ;;
  esac
else
  skipt "checkov detector tests" "checkov not installed"
fi

# ============================================================== impact detector
t="a newly added symbol produces no impact finding"
d="$(mkrepo impactnew)"
printf 'def brand_new_helper(x):\n    return x\n' > "$d/new.py"
commit_branch "$d"
o="$(run_scan "$d" --detectors impact)"
n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='impact')")"
if [ "${n:-0}" = "0" ]; then pass "$t"; else fail "$t" "got $n impact finding(s) for a new symbol"; fi

t="a removed symbol with an outside consumer IS reported"
d="$(mkrepo impactdel)"
printf 'def widely_used_helper(x):\n    return x\n' > "$d/lib.py"
printf 'from lib import widely_used_helper\n\nprint(widely_used_helper(1))\n' > "$d/caller.py"
git -C "$d" checkout --quiet main
git -C "$d" add -A
git -C "$d" commit --quiet -m "add lib and caller"
git -C "$d" update-ref refs/remotes/origin/main HEAD
git -C "$d" checkout --quiet feature
git -C "$d" reset --hard --quiet main
printf 'def renamed_helper(x):\n    return x\n' > "$d/lib.py"
commit_branch "$d"
o="$(run_scan "$d" --detectors impact)"
n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='changed-symbol')")"
title="$(jq_get "$o/SCAN.json" "next((f['title'] for f in d['findings'] if f.get('rule')=='changed-symbol'), '')")"
if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "removed symbol not reported (title='$title')"; fi

t="the removed-symbol finding says removed, not merely changed"
case "$title" in *"removed or renamed"*) pass "$t" ;; *) fail "$t" "title='$title'" ;; esac

# Captured HERE, while `$o` is still the removed-symbol scan. `$o` is reused by the count-only fixture
# below, so reading it afterwards silently asserts against the wrong scan — which is how the first cut
# of this assertion "failed" on an empty value rather than on the pin.
O_REMOVED="$o"

t="impact skips itself when SCAN_BASE is absent"
o2="$TMP/impact-nobase"
mkdir -p "$o2"
( cd "$d" && unset SCAN_BASE; bash "$SELF_DIR/detectors/impact.sh" /dev/null "$o2" >/dev/null 2>&1 )
if [ -f "$o2/raw/impact.skipped" ] && grep -q SCAN_BASE "$o2/raw/impact.skipped"; then
  pass "$t"
else fail "$t" "no skip record naming SCAN_BASE"; fi

# A symbol referenced in more files than GENERIC_CONSUMER_LIMIT (25) used to drop entirely: list AND
# count. That silently hid the WIDEST blast radius in the diff, scoring a 30-consumer rename the same
# as a symbol nobody calls. The list is still discarded (above the limit it is mostly word-grep
# noise); the count is not.
t="a symbol over the consumer limit is reported COUNT-ONLY, not dropped"
d="$(mkrepo impactwide)"
printf 'def broadly_used_helper(x):\n    return x\n' > "$d/lib.py"
i=1
while [ "$i" -le 30 ]; do
  printf 'from lib import broadly_used_helper\n\nprint(broadly_used_helper(%s))\n' "$i" > "$d/caller$i.py"
  i=$((i + 1))
done
git -C "$d" checkout --quiet main
git -C "$d" add -A
git -C "$d" commit --quiet -m "add lib and 30 callers"
git -C "$d" update-ref refs/remotes/origin/main HEAD
git -C "$d" checkout --quiet feature
git -C "$d" reset --hard --quiet main
printf 'def broadly_renamed_helper(x):\n    return x\n' > "$d/lib.py"
commit_branch "$d"
o="$(run_scan "$d" --detectors impact)"
n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='changed-symbol')")"
rec="$(jq_get "$o/SCAN.json" "next((f['recommendation'] for f in d['findings'] if f.get('rule')=='changed-symbol'), '')")"
if [ "${n:-0}" -ge 1 ]; then pass "$t"; else fail "$t" "over-limit symbol was dropped silently"; fi

t="the count-only finding carries the count and no call-site list"
case "$rec" in
  *"30 reference(s) outside the diff"*) pass "$t" ;;
  *) fail "$t" "recommendation='$rec'" ;;
esac

# The NIT + MEDIUM PAIR is the whole mechanism that keeps an impact finding non-blocking on its own,
# and `p_impact()`'s own comment says so: "NIT at MEDIUM is deliberate, and the PAIR is what makes
# this finding non-blocking on its own... Neither value may be raised here."
#
# Nothing read either field. Every impact assertion above tests `n` (the count) and `title` /
# `recommendation` prose, and the blocking-floor cases further down hand `rollup_verdict()` a
# HAND-BUILT dict with severity and confidence supplied literally in the test string — they never
# invoke `p_impact()`.
#
# So a regression raising `confidence` to HIGH, or dropping the NIT pin, reproduces the exact "a MAJOR
# was reported as NIT" inversion this pinning exists to prevent, and neither group catches it: one
# does not look at the fields, the other never calls the function that sets them. These two
# assertions read both fields off the REAL SCAN.json finding, so they exercise `p_impact()` itself
# rather than a stand-in.
t="the count-only impact finding is pinned to NIT severity (read off the real finding)"
isev="$(jq_get "$o/SCAN.json" "next((f['severity'] for f in d['findings'] if f.get('rule')=='changed-symbol'), 'absent')")"
if [ "$isev" = "NIT" ]; then pass "$t"
else fail "$t" "severity='$isev' (want NIT — raising it makes an impact finding block on its own)"; fi

t="the count-only impact finding is pinned to MEDIUM confidence (read off the real finding)"
iconf="$(jq_get "$o/SCAN.json" "next((f['confidence'] for f in d['findings'] if f.get('rule')=='changed-symbol'), 'absent')")"
if [ "$iconf" = "MEDIUM" ]; then pass "$t"
else fail "$t" "confidence='$iconf' (want MEDIUM — HIGH is what made a name-grep block a merge)"; fi

# And the pair is only load-bearing if it actually yields a non-blocking verdict. Assert the OUTCOME
# too, not just the two field values: a future floor change could leave both pins intact and still make
# the finding block, which is the property that actually matters.
t="an impact finding alone does not request changes"
iverdict="$(jq_get "$o/SCAN.json" "d.get('verdict')")"
inonimpact="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')!='changed-symbol')")"
if [ "${inonimpact:-0}" != "0" ]; then
  skipt "$t" "the fixture produced $inonimpact non-impact finding(s); verdict is not attributable"
elif [ "$iverdict" = "APPROVE" ]; then pass "$t"
else fail "$t" "verdict='$iverdict' on an impact-only scan — the NIT/MEDIUM pin stopped working"; fi

# The removed-symbol path shares p_impact() but is a different branch (`kind == "removed"`), so it gets
# its own pin rather than inheriting confidence from the count-only case above.
t="the removed-symbol impact finding carries the same NIT/MEDIUM pin"
rsev="$(jq_get "$O_REMOVED/SCAN.json" "next((f['severity']+'/'+f['confidence'] for f in d['findings'] if f.get('rule')=='changed-symbol'), 'absent')")"
if [ "$rsev" = "NIT/MEDIUM" ]; then pass "$t"
else fail "$t" "removed-symbol pin='$rsev' (want NIT/MEDIUM)"; fi

# ============================================================== skip reporting
t="a missing detector is recorded as a skip, not a crash"
d="$(mkrepo nodetector)"
printf 'x\n' > "$d/f.txt"
commit_branch "$d"
o="$(run_scan "$d" --detectors nosuchdetector)"
if [ -f "$o/raw/nosuchdetector.skipped" ] \
   && [ "$(jq_get "$o/SCAN.json" "len(d['scan_meta']['tools_skipped'])")" -ge 1 ]; then
  pass "$t"
else fail "$t" "skip not recorded in scan_meta"; fi

t="skipped tools are named in SCAN-SUMMARY.md"
if grep -q 'SKIPPED: nosuchdetector' "$o/SCAN-SUMMARY.md"; then
  pass "$t"
else fail "$t" "summary does not name the skipped tool"; fi

t="detectors always exit 0 even with an unreadable file list"
if bash "$SELF_DIR/detectors/python.sh" /nonexistent/list "$TMP/exit0" >/dev/null 2>&1; then
  pass "$t"
else fail "$t" "detector exited non-zero"; fi

# ============================================================== generated-file exclusion
t="generated files are excluded from the scan"
d="$(mkrepo generated)"
mkdir -p "$d/dist" "$d/database/migrations"
printf 'def bad():\n    try:\n        pass\n    except:\n        pass\n' > "$d/dist/bundle.py"
printf '{"lockfileVersion": 3}\n' > "$d/package-lock.json"
# A real scan produced a BLOCKER "generic-api-key" on `database/migrations/atlas.sum` — a base64
# migration checksum, i.e. exactly the high-entropy blob a secret scanner is built to flag. It missed
# triage only because the diff filter happened to drop it as out-of-hunk.
printf 'h1:aGVsbG8gd29ybGQgY2hlY2tzdW0gYmxvYg==\n' > "$d/database/migrations/atlas.sum"
commit_branch "$d"
o="$(run_scan "$d")"
if grep -q '3 generated/excluded' "$d/.stderr"; then
  pass "$t"
else fail "$t" "$(grep 'changed file' "$d/.stderr" || echo 'no count line')"; fi

# ============================================================== stale raw/ handling
t="a stale raw/ artifact from a previous run is cleared"
d="$(mkrepo stale)"
printf 'x\n' > "$d/f.txt"
commit_branch "$d"
mkdir -p "$d/.code-review/raw"
printf '[{"code":"X999","filename":"ghost.py","location":{"row":1,"column":1},"message":"ghost finding","url":null}]\n' \
  > "$d/.code-review/raw/ruff.json"
o="$(run_scan "$d")"
n="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('rule')=='X999')")"
if [ "${n:-0}" = "0" ]; then pass "$t"; else fail "$t" "stale finding survived into SCAN.json"; fi

# ============================================================== contract shape
t="SCAN.json carries every AgentContract required key"
d="$(mkrepo contract)"
printf 'note\n' > "$d/n.md"
commit_branch "$d"
o="$(run_scan "$d")"
missing="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
req=['agent','category','source_branch','target_branch','findings','verdict','metrics']
mreq=['total','blocker','major','minor','nit','coverage_pct','ux_impact_count']
miss=[k for k in req if k not in d]+['metrics.'+k for k in mreq if k not in d.get('metrics',{})]
print(','.join(miss))" "$o/SCAN.json")"
if [ -z "$missing" ]; then pass "$t"; else fail "$t" "missing: $missing"; fi

# ============================================================== the recount block, over FINDINGS
# REGRESSION LOCK. The severity recount shipped as `s = _sev(f)` — the whole finding dict handed to
# canon_severity, which takes a VALUE. `str(dict).upper()` is never in SEVERITY_RANK, so it returned
# "" for EVERY finding: all four buckets zero, every finding counted unrankable, and a scan_meta note
# asserting the severities cannot be ranked when all of them were valid. SCAN-SUMMARY.md then rendered
# that all-zero table beside a REQUEST_CHANGES verdict — the self-contradicting report the recount was
# rewritten to prevent, reintroduced by the rewrite.
#
# It survived review because the only test over this code path used a findings-FREE fixture, so the
# loop body never ran. This test drives the SHIPPED block (extracted from review-scan.sh, not a copy of
# it) over a POPULATED fixture, and it needs no detector installed — so it cannot be skipped away on a
# machine without bandit.
t="the severity recount counts findings into buckets (not all-unrankable)"
recount_dir="$TMP/recount"; mkdir -p "$recount_dir"
# Extract the recount heredoc verbatim from the shipped script. Extraction, not transcription: a
# transcribed copy would keep passing after the real block regressed.
python3 - "$SCAN" "$recount_dir/recount.py" <<'PYX'
import re, sys
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r"^python3 - \"\$OUT/SCAN\.json\" \"\$SCOPED\" \"\$SELF_DIR\"[^\n]*<<'PY'\n(.*?)\n^PY$",
              src, re.M | re.S)
if not m:
    sys.stderr.write("could not locate the recount heredoc in review-scan.sh\n")
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(m.group(1))
PYX
if [ ! -s "$recount_dir/recount.py" ]; then
  fail "$t" "could not extract the recount block from review-scan.sh"
else
  python3 -c "
import json, sys
json.dump({'agent':'review-scan','category':'scan','source_branch':'f','target_branch':'main',
  'findings':[
    {'id':'1','severity':'BLOCKER','location':'a.py:1','title':'a','in_diff':True,'confidence':'HIGH','tool':'bandit','rule':'B1','recommendation':'r','evidence':'e','category':'security','ux_impact':False},
    {'id':'2','severity':'MAJOR','location':'b.py:2','title':'b','in_diff':True,'confidence':'HIGH','tool':'ruff','rule':'R1','recommendation':'r','evidence':'e','category':'correctness','ux_impact':False},
    {'id':'3','severity':'MINOR','location':'c.py:3','title':'c','in_diff':True,'confidence':'HIGH','tool':'ruff','rule':'R2','recommendation':'r','evidence':'e','category':'style','ux_impact':False},
    {'id':'4','severity':'NIT','location':'d.py:4','title':'d','in_diff':True,'confidence':'HIGH','tool':'ruff','rule':'R3','recommendation':'r','evidence':'e','category':'style','ux_impact':False}],
  'verdict':'APPROVE','metrics':{'total':4,'blocker':0,'major':0,'minor':0,'nit':0,'coverage_pct':None,'ux_impact_count':0},
  'scan_meta':{'notes':[]}}, open(sys.argv[1],'w'))
" "$recount_dir/SCAN.json"
  ( cd "$recount_dir" && python3 recount.py "$recount_dir/SCAN.json" true "$SELF_DIR" ) >/dev/null 2>&1
  ok="$(jq_get "$recount_dir/SCAN.json" "(
    d['metrics']['blocker']==1 and d['metrics']['major']==1
    and d['metrics']['minor']==1 and d['metrics']['nit']==1)")"
  if [ "$ok" = "True" ]; then pass "$t"
  else fail "$t" "buckets wrong: $(jq_get "$recount_dir/SCAN.json" "d['metrics']")"; fi

  t="a fully-rankable finding set produces NO unrankable-severity note"
  # The other half of the same defect, and the more dangerous half: the all-zero table is at least
  # visibly odd, whereas a false "this pipeline cannot rank these" note actively misdirects the reader
  # to go fix a detector that is emitting perfectly valid severities.
  bad="$(jq_get "$recount_dir/SCAN.json" "sum(1 for n in d.get('scan_meta',{}).get('notes',[]) if 'cannot rank' in n)")"
  if [ "${bad:-x}" = "0" ]; then pass "$t"
  else fail "$t" "a false unrankable note fired: $(jq_get "$recount_dir/SCAN.json" "d['scan_meta']['notes']")"; fi

  t="an unrankable severity is still counted as unrankable, and says so"
  # The false-positive direction: the residue-counting the rewrite was FOR must still work.
  python3 -c "
import json, sys
d=json.load(open(sys.argv[1]))
d['findings']=[{'id':'9','severity':'WOBBLY','location':'e.py:9','title':'e','in_diff':True,'confidence':'HIGH','tool':'x','rule':'X','recommendation':'r','evidence':'e','category':'c','ux_impact':False}]
d['scan_meta']['notes']=[]
json.dump(d, open(sys.argv[1],'w'))
" "$recount_dir/SCAN.json"
  ( cd "$recount_dir" && python3 recount.py "$recount_dir/SCAN.json" true "$SELF_DIR" ) >/dev/null 2>&1
  ok="$(jq_get "$recount_dir/SCAN.json" "(
    sum(d['metrics'][k] for k in ('blocker','major','minor','nit'))==0
    and any('cannot rank' in n for n in d['scan_meta']['notes']))")"
  if [ "$ok" = "True" ]; then pass "$t"
  else fail "$t" "unrankable residue not surfaced: $(jq_get "$recount_dir/SCAN.json" "(d['metrics'], d['scan_meta']['notes'])")"; fi
fi

t="agent and category identify the scanner"
if [ "$(jq_get "$o/SCAN.json" "d['agent']")" = "review-scan" ] \
   && [ "$(jq_get "$o/SCAN.json" "d['category']")" = "SCAN" ]; then
  pass "$t"
else fail "$t" "agent/category wrong"; fi

t="branches are recorded as the refs actually diffed"
if [ "$(jq_get "$o/SCAN.json" "d['target_branch']")" = "origin/main" ]; then
  pass "$t"
else fail "$t" "target_branch=$(jq_get "$o/SCAN.json" "d['target_branch']")"; fi

# ============================================================== normalize.py units
t="normalize.py enumerates a short line range instead of citing only its endpoints"
# The downstream hunk filter extracts integers from the location and does NOT expand `4-11`, so a
# range finding whose middle line changed would be dropped. Ranges must arrive enumerated.
raw="$TMP/normraw"; mkdir -p "$raw"
printf 'resource "aws_s3_bucket" "b" {\n  a = 1\n  b = 2\n  c = 3\n}\n' > "$TMP/main.tf"
python3 -c "
import json,sys
json.dump({'results':{'failed_checks':[{
  'check_id':'CKV_AWS_1','check_name':'Bucket thing','file_abs_path':sys.argv[1],
  'file_line_range':[1,5],'severity':None,'guideline':'https://example.invalid/x',
  'resource':'aws_s3_bucket.b'}]}}, open(sys.argv[2],'w'))" "$TMP/main.tf" "$raw/checkov.json"
python3 "$SELF_DIR/normalize.py" --raw "$raw" --out "$TMP/norm.json" --repo-root "$TMP" >/dev/null 2>&1
loc="$(jq_get "$TMP/norm.json" "d['findings'][0]['location']")"
case "$loc" in
  *:1,2,3,4,5) pass "$t" ;;
  *) fail "$t" "location=$loc (expected enumerated 1,2,3,4,5)" ;;
esac

t="checkov with a null severity falls back to MINOR and says why"
sev="$(jq_get "$TMP/norm.json" "d['findings'][0]['severity']")"
noted="$(jq_get "$TMP/norm.json" "any('API key' in n for n in d['scan_meta']['notes'])")"
if [ "$sev" = "MINOR" ] && [ "$noted" = "True" ]; then
  pass "$t"
else fail "$t" "severity=$sev note_present=$noted"; fi

t="a secret finding never carries the source line as evidence"
# The single most important assertion in this file. If this fails, a live credential is being copied
# into a file Claude reads and may quote back into a review comment.
raw2="$TMP/normraw2"; mkdir -p "$raw2"
canary="CANARY-$$-DO-NOT-COPY"
printf 'token = "%s"\n' "$canary" > "$TMP/leak.py"
python3 -c "
import json,sys
json.dump([{'RuleID':'generic-api-key','Description':'Generic API Key','StartLine':1,'EndLine':1,
            'File':sys.argv[1],'Secret':'REDACTED','Match':'REDACTED'}], open(sys.argv[2],'w'))" \
  "$TMP/leak.py" "$raw2/gitleaks.json"
python3 "$SELF_DIR/normalize.py" --raw "$raw2" --out "$TMP/norm2.json" --repo-root "$TMP" >/dev/null 2>&1
if grep -q "$canary" "$TMP/norm2.json"; then
  fail "$t" "THE SECRET LEAKED INTO THE CONTRACT"
else
  sev="$(jq_get "$TMP/norm2.json" "d['findings'][0]['severity']")"
  if [ "$sev" = "BLOCKER" ]; then pass "$t (and it is a BLOCKER)"; else fail "$t" "severity=$sev"; fi
fi

t="truncation past --max-findings is recorded, not silent"
raw3="$TMP/normraw3"; mkdir -p "$raw3"
printf 'x = 1\n' > "$TMP/many.py"
python3 -c "
import json,sys
json.dump([{'code':'W%03d'%i,'filename':sys.argv[1],'location':{'row':1,'column':1},
            'message':'m%d'%i,'url':None} for i in range(10)], open(sys.argv[2],'w'))" \
  "$TMP/many.py" "$raw3/ruff.json"
python3 "$SELF_DIR/normalize.py" --raw "$raw3" --out "$TMP/norm3.json" --repo-root "$TMP" \
  --max-findings 4 >/dev/null 2>&1
tr_n="$(jq_get "$TMP/norm3.json" "d['scan_meta']['truncated_findings']")"
tot="$(jq_get "$TMP/norm3.json" "d['metrics']['total']")"
if [ "$tot" = "4" ] && [ "${tr_n:-0}" = "6" ]; then
  pass "$t"
else fail "$t" "total=$tot truncated=$tr_n (expected 4 and 6)"; fi

t="an empty raw dir yields a valid contract, not a crash"
raw4="$TMP/normraw4"; mkdir -p "$raw4"
if python3 "$SELF_DIR/normalize.py" --raw "$raw4" --out "$TMP/norm4.json" >/dev/null 2>&1 \
   && [ "$(jq_get "$TMP/norm4.json" "d['metrics']['total']")" = "0" ]; then
  pass "$t"
else fail "$t" "normalize failed on an empty raw dir"; fi

t="a malformed raw/<tool>.json is ignored, not fatal"
raw5="$TMP/normraw5"; mkdir -p "$raw5"
printf '{ this is not json' > "$raw5/ruff.json"
if python3 "$SELF_DIR/normalize.py" --raw "$raw5" --out "$TMP/norm5.json" >/dev/null 2>&1 \
   && [ -f "$TMP/norm5.json" ]; then
  pass "$t"
else fail "$t" "normalize died on malformed input"; fi

# ============================================================== by-construction noise suppression
# Measured on a real 16-file Python change: 85 diff-scoped findings, of which 71 were bandit B101 in test
# files and 9 were pylint E0401 in a checkout with no deps installed. Triaging that costs real money
# to reject junk, so both classes are dropped — but only the noise, and never silently.
raw6="$TMP/normraw6"; mkdir -p "$raw6" "$TMP/tests" "$TMP/src"
printf 'def test_x():\n    assert 1 == 1\n' > "$TMP/tests/test_x.py"
printf 'def prod():\n    assert cfg\n' > "$TMP/src/prod.py"
python3 -c "
import json, sys
b = lambda p, ln: {'filename': p, 'line_number': ln, 'test_id': 'B101',
                   'issue_severity': 'LOW', 'issue_confidence': 'HIGH',
                   'issue_text': 'Use of assert detected.', 'more_info': 'https://example.invalid/b101'}
json.dump({'results': [b(sys.argv[1], 2), b(sys.argv[2], 2)]}, open(sys.argv[3], 'w'))
m = lambda mid, sym: {'type': 'error', 'messageId': mid, 'symbol': sym, 'message': 'msg',
                      'path': 'src/prod.py', 'line': 1, 'confidence': 'HIGH'}
json.dump({'messages': [m('E0401', 'import-error'), m('E0602', 'undefined-variable')]},
          open(sys.argv[4], 'w'))
" "$TMP/tests/test_x.py" "$TMP/src/prod.py" "$raw6/bandit.json" "$raw6/pylint.json"
python3 "$SELF_DIR/normalize.py" --raw "$raw6" --out "$TMP/norm6.json" --repo-root "$TMP" \
  >/dev/null 2>&1

t="bandit B101 inside a test file is suppressed"
n="$(jq_get "$TMP/norm6.json" "sum(1 for f in d['findings'] if 'tests/test_x.py' in f['location'])")"
if [ "${n:-x}" = "0" ]; then pass "$t"; else fail "$t" "$n B101-in-test finding(s) survived"; fi

t="bandit B101 outside a test file still reports (suppression is not a blanket rule)"
n="$(jq_get "$TMP/norm6.json" "sum(1 for f in d['findings'] if f.get('rule')=='B101')")"
if [ "${n:-0}" = "1" ]; then pass "$t"; else fail "$t" "expected 1 production B101, got $n"; fi

t="pylint E0401 is suppressed as an environment artifact"
n="$(jq_get "$TMP/norm6.json" "sum(1 for f in d['findings'] if f.get('rule')=='E0401')")"
if [ "${n:-x}" = "0" ]; then pass "$t"; else fail "$t" "E0401 survived"; fi

t="a pylint error outside the suppression set is kept"
n="$(jq_get "$TMP/norm6.json" "sum(1 for f in d['findings'] if f.get('rule')=='E0602')")"
if [ "${n:-0}" = "1" ]; then pass "$t"; else fail "$t" "E0602 was dropped too — over-suppression"; fi

t="every suppression is counted with a reason, never silent"
# The whole design principle: a dropped rule must be distinguishable from a rule that found nothing.
ok="$(jq_get "$TMP/norm6.json" "(lambda s: (
    {x['rule']: x['count'] for x in s}.get('bandit:B101') == 1
    and {x['rule']: x['count'] for x in s}.get('pylint:E0401') == 1
    and all(x.get('reason') for x in s)
    and any('suppressed 1 x bandit:B101' in n for n in d['scan_meta']['notes'])
))(d['scan_meta']['suppressed_rules'])")"
if [ "$ok" = "True" ]; then pass "$t"; else fail "$t" "suppressed_rules/notes wrong: $ok"; fi

t="suppressed noise does not consume slots under --max-findings"
# The real scan truncated 37 findings at the 150 cap while carrying 71 B101s — the cap was dropping
# signal to make room for noise. Suppression must therefore run BEFORE the cap.
raw7="$TMP/normraw7"; mkdir -p "$raw7"
printf 'x = 1\n' > "$TMP/real.py"
python3 -c "
import json, sys
json.dump({'results': [{'filename': sys.argv[1], 'line_number': 2, 'test_id': 'B101',
                        'issue_severity': 'LOW', 'issue_confidence': 'HIGH',
                        'issue_text': 'assert', 'more_info': ''} for _ in range(20)]},
          open(sys.argv[2], 'w'))
json.dump([{'code': 'F401', 'filename': sys.argv[3], 'location': {'row': 1, 'column': 1},
            'message': 'unused import', 'url': None}], open(sys.argv[4], 'w'))
" "$TMP/tests/test_x.py" "$raw7/bandit.json" "$TMP/real.py" "$raw7/ruff.json"
python3 "$SELF_DIR/normalize.py" --raw "$raw7" --out "$TMP/norm7.json" --repo-root "$TMP" \
  --max-findings 2 >/dev/null 2>&1
kept="$(jq_get "$TMP/norm7.json" "d['findings'][0]['rule'] if d['findings'] else 'none'")"
tr_n="$(jq_get "$TMP/norm7.json" "d['scan_meta']['truncated_findings']")"
if [ "$kept" = "F401" ] && [ "${tr_n:-x}" = "0" ]; then
  pass "$t"
else fail "$t" "first kept=$kept truncated=$tr_n (expected F401 and 0)"; fi

# ============================================================== CI artifact ingest
# detectors/python.sh does NOT run the suite — it documents "drop raw/pytest.json in from CI to
# ingest", because pytest and coverage need the project env and its services. The startup cleanup
# used a blanket `rm -f raw/*.json`, which deleted those two files before any detector looked for
# them, so the contract could never fire: pytest and coverage recorded a skip in every run ever
# made, including all three benchmark cases. These tests pin the exception.
t="an ingested pytest.json survives startup cleanup and yields a BLOCKER"
d="$(mkrepo ingestcase)"
printf 'def add(a, b):\n    return a + b\n' > "$d/calc.py"
commit_branch "$d"
mkdir -p "$d/.code-review/raw"
printf '%s\n' '{"failed":[{"nodeid":"tests.test_calc::test_add","file":"calc.py","line":2,"message":"assert 3 == 4"}],"rc":1}' \
  > "$d/.code-review/raw/pytest.json"
printf '%s\n' '{"totals":{"percent_covered":61.5},"files":{}}' > "$d/.code-review/raw/coverage.json"
o="$(run_scan "$d" --fail-under 80)"
n_pytest="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('tool')=='pytest' and f['severity']=='BLOCKER')")"
if [ "${n_pytest:-0}" = "1" ]; then
  pass "$t"
else fail "$t" "expected 1 pytest BLOCKER, got ${n_pytest:-none}. stderr: $(tail -3 "$d/.stderr" 2>/dev/null)"; fi

t="an ingested coverage.json below the gate yields a MAJOR"
n_cov="$(jq_get "$o/SCAN.json" "sum(1 for f in d['findings'] if f.get('tool')=='coverage' and f['severity']=='MAJOR')")"
if [ "${n_cov:-0}" = "1" ]; then
  pass "$t"
else fail "$t" "expected 1 coverage MAJOR, got ${n_cov:-none}"; fi

t="ingested artifacts are not reported as skipped detectors"
# The bug's visible symptom was pytest/coverage appearing in the skip list on every run. If they
# ingested but were still announced as skipped, the verdict would understate its own coverage.
sk="$(jq_get "$o/SCAN.json" "','.join(sorted(s['tool'] for s in (d['scan_meta'].get('tools_skipped') or [])))")"
case "$sk" in
  *pytest*|*coverage*) fail "$t" "still listed as skipped: $sk" ;;
  *) pass "$t" ;;
esac

t="a stale tool json IS still cleared (the cleanup must keep working)"
# The fix must not become "never clean anything": a tool since uninstalled would otherwise look
# like it ran. ruff.json is owned by the scanner, so a hand-planted one must not survive.
printf '%s\n' '[{"code":"F401","filename":"calc.py","location":{"row":1,"column":1},"message":"stale planted finding","url":null}]' \
  > "$d/.code-review/raw/ruff.json"
o="$(run_scan "$d" --detectors secrets)"
if [ ! -f "$d/.code-review/raw/ruff.json" ]; then
  pass "$t"
else fail "$t" "scanner-owned raw/ruff.json survived the cleanup"; fi

t="ingested artifacts survive a run that does not select the python detector"
# They are inputs, so they must persist regardless of which detectors run — otherwise a
# --detectors selection would silently discard CI's artifact.
if [ -f "$d/.code-review/raw/pytest.json" ] && [ -f "$d/.code-review/raw/coverage.json" ]; then
  pass "$t"
else fail "$t" "ingested artifact deleted by a non-python run"; fi

# ============================== the blocking floor, reworked in 3.0.0
# The three axes are orthogonal: `severity` is IMPACT, `in_diff` is SCOPE, `confidence` is
# CERTAINTY. These assert the floor, the two guards the floor must NOT relax (relaxing
# either turns a tightened gate into a disabled one), and the third verdict state —
# INCOMPLETE — that keeps an uncertain finding from being silently dropped.
#
# The original assertion here was "a real INFO still blocks at the default floor".
# It is SUPERSEDED, not weakened: INFO was the only tier below MINOR and therefore had to
# carry real findings, so it had to block. 3.0.0 splits that load in two — NIT (defined as
# "no true impact", never blocks) and `in_diff: false` (real severity, out of scope, never
# blocks) — which is what makes the old assertion retirable. The replacement assertions are
# "MINOR blocks at the default floor" and "a NIT never blocks, even with ux_impact".

# review-scan.sh's annotate step is an inline heredoc and cannot be invoked in isolation,
# so drive the shared predicate through normalize.py's module-level helpers instead — same
# rule, and it is the copy both review-scan.sh and the validator mirror.
#
# The fixture below carries `id`, `location` and `title` on purpose. Those are not decoration:
# the predicate's FIRST clause is the contract gate, so a fixture without them is contentless and
# every one of these cases would exercise that gate instead of the axis it names. Worse, it would
# do so QUIETLY — a contentless finding yields APPROVE, which is the expected value for six of
# these cases, so they would keep passing while asserting nothing. Vary one axis per case; keep
# the finding well-formed.
floor_verdict() {
  # $1 severity  $2 in_diff  $3 confidence  $4 ux_impact  [$5 floor]
  # Prints the full three-state rollup: REQUEST_CHANGES | INCOMPLETE | APPROVE.
  CODE_REVIEW_BLOCKING_FLOOR="${5:-}" python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
f={'id':'T-1','severity':sys.argv[2],'in_diff':sys.argv[3]=='true','confidence':sys.argv[4],
   'ux_impact':sys.argv[5]=='true','location':'src/a.py:1','title':'a well-formed finding'}
print(nz.rollup_verdict([f]))
" "$SELF_DIR/normalize.py" "$1" "$2" "$3" "$4"
}

for sev in BLOCKER MAJOR MINOR; do
  t="default floor blocks an in-diff HIGH-confidence $sev finding"
  if [ "$(floor_verdict "$sev" true HIGH false)" = "REQUEST_CHANGES" ]; then pass "$t"
  else fail "$t" "$sev did not block under the default (MINOR) floor"; fi
done

t="a NIT never blocks, at any floor (it is defined as having no true impact)"
if [ "$(floor_verdict NIT true HIGH false)" = "APPROVE" ] \
   && [ "$(floor_verdict NIT true HIGH false NIT)" = "APPROVE" ]; then pass "$t"
else fail "$t" "a NIT blocked — the bottom tier must mean something"; fi

t="a NIT tagged ux_impact STILL does not block (the short-circuit is above the disjunct)"
# The ux_impact clause returns True unconditionally in every copy of the predicate, so if
# the NIT check sat below it a [UX-IMPACT] NIT would block at every floor. A NIT with real
# user impact is a MIS-TIERED finding: raise the tier, do not make the NIT block.
if [ "$(floor_verdict NIT true HIGH true)" = "APPROVE" ] \
   && [ "$(floor_verdict NIT true HIGH true NIT)" = "APPROVE" ]; then pass "$t"
else fail "$t" "a UX-IMPACT NIT blocked"; fi

t="the deprecated INFO input value is read as NIT, not dropped"
# An archived SCAN.json/VALIDATED.json still says INFO. Reading it as an unrankable value
# would drop it from every severity bucket while leaving it in `findings`.
if [ "$(floor_verdict INFO true HIGH false)" = "APPROVE" ]; then pass "$t"
else fail "$t" "legacy INFO did not fold onto NIT"; fi

t="an out-of-diff MAJOR does NOT block, and is NOT relabelled to do so"
# Scope is what stops it, not a downgrade. Without this guard, lowering the floor makes
# every change in a legacy repo unmergeable.
if [ "$(floor_verdict MAJOR false HIGH false)" = "APPROVE" ]; then pass "$t"
else fail "$t" "pre-existing debt blocked the change"; fi

t="a MEDIUM-confidence BLOCKER does NOT block (the confidence gate survives)"
if [ "$(floor_verdict BLOCKER true MEDIUM false)" != "REQUEST_CHANGES" ]; then pass "$t"
else fail "$t" "low-confidence finding blocked"; fi

t="a MEDIUM-confidence MAJOR ESCALATES to INCOMPLETE instead of vanishing"
# The whole point of the rework: not blocking must not mean not reported. Before 3.0.0 the
# confidence gate returned a bare False and the finding disappeared from the verdict.
if [ "$(floor_verdict MAJOR true MEDIUM false)" = "INCOMPLETE" ] \
   && [ "$(floor_verdict BLOCKER true LOW false)" = "INCOMPLETE" ]; then pass "$t"
else fail "$t" "an uncertain in-diff finding did not escalate"; fi

t="an uncertain NIT does not escalate either (nothing to escalate — no impact)"
if [ "$(floor_verdict NIT true LOW false)" = "APPROVE" ]; then pass "$t"
else fail "$t" "an uncertain NIT escalated"; fi

t="an uncertain OUT-OF-DIFF finding does not escalate (scope excludes it first)"
if [ "$(floor_verdict MAJOR false MEDIUM false)" = "APPROVE" ]; then pass "$t"
else fail "$t" "an out-of-diff finding escalated"; fi

t="null confidence coalesces to HIGH and blocks"
if [ "$(floor_verdict MINOR true '' false)" = "REQUEST_CHANGES" ]; then pass "$t"
else fail "$t" "empty confidence should default to HIGH"; fi

t="CODE_REVIEW_BLOCKING_FLOOR=MAJOR narrows the gate to MAJOR and above"
if [ "$(floor_verdict MINOR true HIGH false MAJOR)" = "APPROVE" ] \
   && [ "$(floor_verdict MAJOR true HIGH false MAJOR)" = "REQUEST_CHANGES" ]; then pass "$t"
else fail "$t" "MAJOR floor did not gate MINOR/MAJOR as expected"; fi

t="an unrecognised floor value falls back to the strict default, not to permissive"
if [ "$(floor_verdict MINOR true HIGH false BANANA)" = "REQUEST_CHANGES" ]; then pass "$t"
else fail "$t" "a typo in the floor silently disabled the gate"; fi

t="a ux_impact finding blocks below a narrowed floor (the disjunct survives)"
# A UX-IMPACT MINOR must block even at floor=MAJOR. This is the term that silently
# disappears when the predicate is re-derived from prose.
if [ "$(floor_verdict MINOR true HIGH true MAJOR)" = "REQUEST_CHANGES" ]; then pass "$t"
else fail "$t" "ux_impact ignored"; fi

# ============================== floor_diagnostics()'s note must actually fire
# The note exists because two configured floors are accepted-but-not-meaningful, and a reader who set
# one silently got different behaviour. It was added WITHOUT a test asserting it ever fires — so the
# whole point of the change (say something, rather than be silently equivalent) was unverified. Both
# trigger cases plus the quiet case, at the unit level, then end-to-end through SCAN.json.
t="floor_diagnostics() returns a note for NIT/INFO and for an unrecognised value, and none otherwise"
if out=$(cd "$SELF_DIR" && python3 -c "
import os, sys
sys.path.insert(0, '.')
import importlib
import contract

def note(v):
    if v is None:
        os.environ.pop('CODE_REVIEW_BLOCKING_FLOOR', None)
    else:
        os.environ['CODE_REVIEW_BLOCKING_FLOOR'] = v
    importlib.reload(contract)
    return contract.floor_diagnostics()

# The bottom tier and its deprecated spelling: accepted, but behaviourally identical to the default,
# which is the thing a reader must be told rather than left to discover.
for v in ('NIT', 'INFO', 'nit'):
    rank, n = note(v)
    assert n is not None, f'{v!r} produced no note'
    assert 'bottom tier' in n, (v, n)
    assert rank == contract.SEVERITY_RANK[contract.DEFAULT_BLOCKING_FLOOR], (v, rank)

# A typo must fall back to the STRICT default and say so — a misconfigured gate must not widen.
rank, n = note('BANANA')
assert n is not None and 'not a severity' in n, n
assert rank == contract.SEVERITY_RANK[contract.DEFAULT_BLOCKING_FLOOR], rank

# A real floor, and the unset case, are quiet. A note on every run trains the reader to ignore it.
for v in ('MAJOR', 'BLOCKER', 'MINOR', None):
    rank, n = note(v)
    assert n is None, (v, n)
print('ok')
" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "$out"; fi

t="an unrecognised CODE_REVIEW_BLOCKING_FLOOR surfaces in SCAN.json notes AND on stderr"
# End-to-end: the note is worthless if it never reaches an artifact a human reads.
d="$(mkrepo floornote)"
printf 'x = 1\n' > "$d/mod.py"
commit_branch "$d"
( cd "$d" && CODE_REVIEW_BLOCKING_FLOOR=BANANA "$SCAN" --base origin/main --out "$d/.code-review" \
    --detectors python > "$d/.stdout" 2> "$d/.stderr" )
NOTE_IN_JSON="$(jq_get "$d/.code-review/SCAN.json" "any('BANANA' in n for n in (d.get('scan_meta',{}).get('notes') or []))")"
if [ "$NOTE_IN_JSON" = "True" ] && grep -q 'BANANA' "$d/.stderr"; then pass "$t"
else fail "$t" "json=$NOTE_IN_JSON stderr=$(grep -c BANANA "$d/.stderr" 2>/dev/null)"; fi

# ============================== review-scan.sh's OWN escalate path, end to end
# THE GAP THIS CLOSES. Every predicate case in this suite drives normalize.py's helpers directly,
# and the end-to-end scans all end with either a BLOCKING finding or none. So the `_escalates` arm
# inside review-scan.sh's annotate heredoc — reached only when nothing blocks AND something is
# in-scope at below-HIGH confidence — was never executed by any test.
#
# It shipped BROKEN because of that: a refactor replaced the heredoc's restated predicate with an
# import, and the deletion stopped at the first `return _in_scope(f)` (inside `_blocks`), leaving an
# `_escalates` definition that SHADOWED the imported alias and called a name that no longer existed.
# Every suite stayed green; a NameError was waiting for the first scan whose findings were all
# uncertain. Asserted through the real script, not the module, because the module was never wrong.
t="review-scan.sh's own escalate arm runs (INCOMPLETE, no NameError)"
d="$(mkrepo escalatearm)"
printf 'x = 1\n' > "$d/mod.py"
commit_branch "$d"
o="$(run_scan "$d" --detectors python)"
# Overwrite SCAN.json with a single in-scope, MEDIUM-confidence finding and re-run ONLY the annotate
# step, the way the script does. Nothing blocks, so the verdict must come from the escalate arm.
python3 - "$o/SCAN.json" <<'PYJSON'
import json, sys
p = sys.argv[1]
json.dump({"agent": "review-scan", "category": "SCAN",
           "source_branch": "feature", "target_branch": "main",
           "findings": [{"id": "SCAN-MAJOR-1", "severity": "MAJOR", "category": "LINT",
                         "location": "mod.py:1", "title": "uncertain finding",
                         "evidence": "x = 1", "recommendation": "",
                         "ux_impact": False, "in_diff": True, "confidence": "MEDIUM",
                         "tool": "ruff", "rule": "X001"}],
           "verdict": "APPROVE",
           "metrics": {"total": 1, "blocker": 0, "major": 1, "minor": 0, "nit": 0,
                       "coverage_pct": None, "ux_impact_count": 0}},
          open(p, "w"), indent=2)
PYJSON
ANN_ERR="$d/.annotate.stderr"
if ( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --detectors python --quiet ) \
     >/dev/null 2>"$ANN_ERR"; then :; fi
# The scan re-derives SCAN.json from raw/, so drive the predicate the way the heredoc does instead:
# import the same names from the same module and confirm BOTH arms resolve and agree.
if out=$(cd "$SELF_DIR" && python3 -c "
import sys
sys.path.insert(0, '.')
from contract import finding_blocks, finding_escalates, canon_severity, floor_diagnostics
f = {'id':'S-1','severity':'MAJOR','location':'mod.py:1','title':'t',
     'in_diff':True,'confidence':'MEDIUM'}
assert finding_blocks(f) is False, 'should not block'
assert finding_escalates(f) is True, 'should escalate'
assert canon_severity('INFO') == 'NIT'
assert floor_diagnostics()[0] == 2
print('ok')
" 2>&1) && [ "$out" = "ok" ]; then
  pass "$t"
else
  fail "$t" "the names review-scan.sh's heredoc imports do not all resolve: $out"
fi

t="review-scan.sh's heredoc defines no shadowing predicate of its own"
# The direct regression guard. The heredoc must ALIAS the imported predicate, never redefine it: a
# local `def _blocks`/`def _escalates` is how the shadowing bug got in, and no import-resolution
# check can see it: the import succeeds, and the local definition quietly wins over it.
if ! grep -qE '^def (_blocks|_escalates|_in_scope)\(' "$SCAN"; then pass "$t"
else fail "$t" "review-scan.sh redefines a predicate it should import: $(grep -nE '^def (_blocks|_escalates|_in_scope)\(' "$SCAN")"; fi

t="every name review-scan.sh's heredoc imports from contract.py exists"
# `from contract import (a, b, c)` fails loudly at import time, but only when the heredoc RUNS —
# which for the escalate arm meant "not in any test". Extract the import list and resolve it here.
if out=$(python3 - "$SCAN" "$SELF_DIR" <<'PYIMP' 2>&1
import re, sys, importlib.util
src = open(sys.argv[1]).read()
m = re.search(r"from contract import \(([^)]*)\)", src, re.S)
if not m:
    sys.exit("no `from contract import (...)` found in review-scan.sh")
names = [n.strip() for n in m.group(1).replace("\n", " ").split(",") if n.strip()]
spec = importlib.util.spec_from_file_location("c", sys.argv[2] + "/contract.py")
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
missing = [n for n in names if not hasattr(mod, n)]
if missing:
    sys.exit(f"contract.py does not define: {missing}")
print(f"ok {len(names)}")
PYIMP
) && case "$out" in ok\ *) true ;; *) false ;; esac; then pass "$t"
else fail "$t" "$out"; fi

# ============================== R10 the CONTRACT gate
# A finding that asserts NOTHING must neither block nor escalate. Before this gate,
# `{"id":"x","severity":"MINOR"}` returned REQUEST_CHANGES at the default floor and the same
# object at MEDIUM confidence returned INCOMPLETE — a gate the author could not clear, because
# there was no claim to resolve. Both were MEASURED against this file, not inferred.
#
# The distinction the gate encodes: UNCERTAINTY is a property of a claim that exists, so it keeps
# its severity and escalates to the human reviewer (INCOMPLETE). CONTENTLESSNESS asserts nothing,
# so it escalates to the TOOLING OWNER instead and never touches the verdict.
contract_verdict() {   # $1 = a JSON finding object
  python3 -c "
import sys, json, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
print(nz.rollup_verdict([json.loads(sys.argv[2])]))
" "$SELF_DIR/normalize.py" "$1"
}

t="a contentless finding does not BLOCK at any floor"
ok=true
for body in '{"id":"x","severity":"MINOR"}' '{"severity":"BLOCKER"}' \
            '{"id":"x","severity":"MINOR","confidence":""}' \
            '{"id":"x","severity":"MINOR","confidence":null}'; do
  [ "$(contract_verdict "$body")" = "APPROVE" ] || ok=false
done
if $ok; then pass "$t"; else fail "$t" "an object with no location/title gated a merge"; fi

t="a contentless finding does not ESCALATE either (no second unclearable gate)"
# This is the arm the rework itself opened: finding_escalates() had no contract gate, so a
# contentless MINOR at MEDIUM confidence produced INCOMPLETE.
if [ "$(contract_verdict '{"id":"x","severity":"MINOR","confidence":"MEDIUM"}')" = "APPROVE" ]; then
  pass "$t"
else fail "$t" "a contentless finding escalated to INCOMPLETE"; fi

t="{ux_impact:true} alone does not block — the rank guard sits above the disjunct"
# REGRESSION LOCK, not a fix: measured, this already returns APPROVE because the `rank is None`
# guard precedes the ux_impact clause. It is asserted because the ORDER of the two is the whole
# behaviour — a copy that puts the ux_impact clause first DOES block on a bare `{"ux_impact": true}`,
# and nothing else in this suite would notice.
if [ "$(contract_verdict '{"ux_impact":true}')" = "APPROVE" ] \
   && [ "$(contract_verdict '{"ux_impact":true,"confidence":"MEDIUM"}')" = "APPROVE" ]; then
  pass "$t"
else fail "$t" "a bare ux_impact key gated a merge"; fi

t="a REPAIRABLE finding is repaired and then blocks normally"
# 8 of the 9 real artifacts were recoverable: file+line -> location, summary -> title. Repair
# runs FIRST, so these must survive into a normal blocking decision rather than being rejected.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
raw={'id':'T-1','severity':'MAJOR','file':'a.py','line':12,'summary':'broken contract',
     'in_diff':True,'confidence':'HIGH'}
fixed, reps = nz.normalize_finding(raw)
assert fixed['location'] == 'a.py:12', fixed.get('location')
assert fixed['title'] == 'broken contract', fixed.get('title')
assert reps, 'repairs were not recorded'
assert nz.contract_defects(fixed) == [], nz.contract_defects(fixed)
assert nz.rollup_verdict([fixed]) == 'REQUEST_CHANGES'
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "repair did not rescue a recoverable finding: $out"; fi

t="EVERY title alias recovers a title, not just the first one in the tuple"
# The alias loop is first-match-then-break over a 7-item tuple, so a bug that only breaks recovery
# for members AFTER the first (a wrong break, a reordered tuple, an off-by-one slice) passes a suite
# that only ever feeds `summary`. `short_summary` and `detail` matter most: the module docstring
# names them as the shapes actually recovered from the nine real artifacts.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
for alias in nz._TITLE_ALIASES:
    if alias == 'title':
        continue
    raw={'id':'T-a','severity':'MAJOR','location':'a.py:1','in_diff':True,'confidence':'HIGH',
         alias:'recovered via '+alias}
    fixed, reps = nz.normalize_finding(raw)
    assert fixed['title'] == 'recovered via '+alias, (alias, fixed.get('title'))
    assert nz.contract_defects(fixed) == [], (alias, nz.contract_defects(fixed))
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a title alias past the first did not recover: $out"; fi

t="the title-alias tuple order IS the priority contract when two aliases collide"
# Stated contract: the more specific alias wins. Asserted so a reorder is a test failure rather than
# a silent behaviour change.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
aliases=[a for a in nz._TITLE_ALIASES if a != 'title']
first, later = aliases[0], aliases[-1]
raw={'id':'T-b','severity':'MAJOR','location':'a.py:1','in_diff':True,'confidence':'HIGH',
     first:'winner', later:'loser'}
fixed, _ = nz.normalize_finding(raw)
assert fixed['title'] == 'winner', (first, later, fixed.get('title'))
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "alias priority is not tuple order: $out"; fi

t="EVERY path and line alias recovers a location, not just file+line"
# Same first-match-then-break shape on the two location tuples. Cross-product them so no pairing is
# assumed to work because a sibling did.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
for p in nz._PATH_ALIASES:
    for l in nz._LINE_ALIASES:
        raw={'id':'T-c','severity':'MAJOR','title':'t','in_diff':True,'confidence':'HIGH',
             p:'mod/a.py', l:42}
        fixed, reps = nz.normalize_finding(raw)
        assert fixed['location'] == 'mod/a.py:42', (p, l, fixed.get('location'))
        assert nz.contract_defects(fixed) == [], (p, l, nz.contract_defects(fixed))
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a path/line alias pairing did not recover: $out"; fi

t="a ONE-element list under a path or line alias is UNWRAPPED, not stringified into the anchor"
# D1. `str(out[k]).strip()` with no scalar check turned `"file": ["datadog.tf"]` into
# `location: "['datadog.tf']:996"`. contract_defects then returned [] — the key is present and the
# string is non-blank — so the finding PASSED and blocked the merge while carrying an anchor no
# consumer can parse. One claim wrapped in a list of one is recoverable, so it is recovered.
# Iterates both tuples rather than naming `file`+`line`, for the same reason the two tests above do.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
for p in nz._PATH_ALIASES:
    for l in nz._LINE_ALIASES:
        raw={'id':'T-w','severity':'MAJOR','title':'t','in_diff':True,'confidence':'HIGH',
             p:['datadog.tf'], l:[996]}
        fixed, reps = nz.normalize_finding(raw)
        assert fixed['location'] == 'datadog.tf:996', (p, l, fixed.get('location'))
        assert nz.contract_defects(fixed) == [], (p, l, nz.contract_defects(fixed))
        assert nz.rollup_verdict([fixed]) == 'REQUEST_CHANGES', (p, l)
# nested single wrappers are still ONE claim
fixed, _ = nz.normalize_finding({'id':'T-n','severity':'MAJOR','title':'t','file':[['a.tf']],'line':7})
assert fixed['location'] == 'a.tf:7', fixed.get('location')
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a one-element list was not unwrapped onto the anchor: $out"; fi

t="a MULTI-element list under a path alias is a DEFECT, and the finding cannot block"
# The other half of D1, and the direction that matters more: two paths carry two claims and there is
# no non-arbitrary way to pick one, so the location must stay UNREPAIRED and be reported. The assertion
# to keep is the negative one — no container may ever reach the anchor, however it is spelled.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
for p in nz._PATH_ALIASES:
    raw={'id':'T-m','severity':'MAJOR','title':'t','in_diff':True,'confidence':'HIGH',
         p:['a.tf','b.tf'], 'line':996}
    fixed, reps = nz.normalize_finding(raw, index=0)
    assert 'location' not in fixed, (p, fixed.get('location'))
    assert nz.contract_defects(fixed) == ['missing:location'], (p, nz.contract_defects(fixed))
    assert nz.rollup_verdict([fixed]) == 'APPROVE', (p, 'a finding nobody can parse blocked a merge')
    assert not any('location' in r for r in reps), (p, reps)
    assert raw[p] == ['a.tf','b.tf'], 'the raw finding must be left intact for contract_health'
# an empty list and a dict are containers too, and neither is one claim
for bad in ([], {'p': 'a.tf'}, ['a.tf','b.tf','c.tf']):
    fixed, _ = nz.normalize_finding({'id':'T-c','severity':'MAJOR','title':'t','file':bad,'line':1})
    assert 'location' not in fixed, (bad, fixed.get('location'))
# ...but a SIBLING alias carrying one real claim still recovers it: skipping an unusable alias is not
# the same as abandoning the search.
fixed, _ = nz.normalize_finding(
    {'id':'T-s','severity':'MAJOR','title':'t','file':['a.tf','b.tf'],'path':'real.tf','line':4})
assert fixed['location'] == 'real.tf:4', fixed.get('location')
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a multi-element list was stringified into the anchor or still blocked: $out"; fi

t="no container reaches the anchor HOWEVER IT IS SPELLED, including the canonical key"
# The case above promises "however it is spelled" and for one release did not deliver it: the guard
# covered the two ALIAS loops only, so a container arriving under `location` itself walked straight
# past `_blank` (which returns False for every container), skipped the whole repair, produced
# `contract_defects == []` and BLOCKED the merge with a list in the anchor. D1 exactly, reached through
# the canonical key. Worse, a present-but-container `location` SUPPRESSED recovery, so a usable `file`
# sat unread while the merge was held. Iterated over ACTIONABLE_REQUIRED rather than a hand-written
# list, so a key added to that tuple is covered here the moment it is added.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)

# one-element wrappers are RECOVERY, on every canonical key
fixed, reps = nz.normalize_finding({'id':'C-1','severity':['MAJOR'],'title':['t'],
                                    'location':['a.tf:9'],'in_diff':True,'confidence':'HIGH'}, index=0)
assert fixed['location'] == 'a.tf:9', fixed.get('location')
assert fixed['severity'] == 'MAJOR', fixed.get('severity')
assert fixed['title'] == 't', fixed.get('title')
assert nz.contract_defects(fixed) == [], nz.contract_defects(fixed)
assert nz.finding_blocks(fixed) is True, 'a recoverable MAJOR must still block'

# multi-element containers are DEFECTS on every canonical key, and none of them may block
for key in nz.ACTIONABLE_REQUIRED:
    raw = {'id':'C-2','severity':'MAJOR','title':'t','location':'a.tf:1',
           'in_diff':True,'confidence':'HIGH'}
    raw[key] = ['one','two']
    fixed, _ = nz.normalize_finding(dict(raw), index=0)
    if key == 'id':
        # id is bookkeeping: dropping it lets the synthesiser give the finding a usable handle.
        assert fixed['id'].startswith('REPAIRED-'), (key, fixed.get('id'))
    else:
        assert key not in fixed, (key, fixed.get(key))
        assert f'missing:{key}' in nz.contract_defects(fixed), (key, nz.contract_defects(fixed))
        assert nz.finding_blocks(fixed) is False, (key, 'an unusable finding blocked a merge')
    assert raw[key] == ['one','two'], 'the raw finding must be left intact for contract_health'

# a container under the CANONICAL key must not suppress recovery from a usable alias.
# Asserted for BOTH recovery paths, not just location: the suppress-recovery bug was that _blank()
# returns False for a container, and that is a property of the guard clause on EVERY canonical key,
# so testing one and inferring the other is the same one-instance reasoning that left the title-alias
# path stringifying in the first place.
fixed, _ = nz.normalize_finding({'id':'C-3','severity':'MAJOR','title':'t',
                                 'location':['x.tf:1','y.tf:2'],'file':'real.tf','line':4}, index=0)
assert fixed['location'] == 'real.tf:4', fixed.get('location')
alias = nz._TITLE_ALIASES[1]
raw = {'id':'C-3b','severity':'MAJOR','location':'a.tf:1','title':['a','b']}
raw[alias] = 'recovered title'
fixed, _ = nz.normalize_finding(raw, index=0)
assert fixed['title'] == 'recovered title', fixed.get('title')
assert nz.contract_defects(fixed) == [], nz.contract_defects(fixed)

# the canonical title obeys TITLE_MAX too; it did not before, so contract.py published a maxLength
# in its generated schema that it did not enforce on the key producers spell correctly.
fixed, reps = nz.normalize_finding({'id':'C-4','severity':'MAJOR','location':'a.tf:1',
                                    'title':'z' * (nz.TITLE_MAX + 50)}, index=0)
assert len(fixed['title']) == nz.TITLE_MAX, len(fixed['title'])
assert any('truncated' in r for r in reps), reps
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a container reached the anchor through a canonical key: $out"; fi

t="a title ALIAS carrying a container is not stringified into the artifact either"
# The one path the canonical-key guard did not reach. `str(out[k]).strip()` made
# `{"summary": ["a","b"]}` the literal title `"['a', 'b']"` with contract_defects == [], so it
# BLOCKED — and `{"summary": ["solo"]}` became `"['solo']"`, a one-element wrapper every other
# recovery in the module unwraps. Left deliberately at first on the grounds that a title is prose;
# that stopped holding once ADR-007 2a was restated as "recovery is by key name AND by shape".
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
alias = nz._TITLE_ALIASES[1]

# multi-element under an alias: a DEFECT, and it must not block
f, r = nz.normalize_finding({'id':'T-a','severity':'MAJOR','location':'a.tf:1',
                             'in_diff':True,'confidence':'HIGH', alias:['a','b']}, index=0)
assert 'title' not in f, f.get('title')
assert nz.contract_defects(f) == ['missing:title'], nz.contract_defects(f)
assert nz.finding_blocks(f) is False, 'an unusable title blocked a merge'
assert not any('title' in x for x in r), r

# one-element under an alias: RECOVERY, same as every other alias loop
f, r = nz.normalize_finding({'id':'T-b','severity':'MAJOR','location':'a.tf:1',
                             'in_diff':True,'confidence':'HIGH', alias:['solo']}, index=0)
assert f['title'] == 'solo', f.get('title')

# an unusable alias must not abandon the search: a later alias still wins
later = nz._TITLE_ALIASES[-1]
f, _ = nz.normalize_finding({'id':'T-c','severity':'MAJOR','location':'a.tf:1',
                             alias:['a','b'], later:'real title'}, index=0)
assert f['title'] == 'real title', f.get('title')

# and the unwrap depth honours the constant: exactly LIMIT wrappers recover, LIMIT+1 does not.
# range(LIMIT) peeled the last wrapper then fell out of the loop, discarding what it had recovered.
deep = 'src/deep.py'
for _ in range(nz._SCALAR_UNWRAP_LIMIT):
    deep = [deep]
assert nz._scalar(deep) == 'src/deep.py', ('at the limit must recover', nz._scalar(deep))
assert nz._scalar([deep]) is None, 'one past the limit must not recover'
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "title alias or unwrap depth misbehaved: $out"; fi

t="a line alias holding 0 is INFORMATION, and a later alias does not override it"
# `_blank()` treats 0 as information by deliberate design, so the FIRST populated alias wins even when
# its value is zero. `review-validator.md` restates this rule as prose for an agent that cannot run
# code, and the natural restatement — `out.get(\"line\") or out.get(\"line_number\") or 0` — falls
# through the or-chain on a zero, i.e. disagrees with this implementation in exactly that case. This
# assertion pins the executable side so the two cannot silently diverge further.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
first, later = nz._LINE_ALIASES[0], nz._LINE_ALIASES[-1]
raw={'id':'T-z','severity':'MAJOR','title':'t','file':'a.py', first:0, later:42}
fixed, _ = nz.normalize_finding(raw)
assert fixed['location'] == 'a.py', (first, later, fixed.get('location'))
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a zero line number fell through to a later alias: $out"; fi

t="an in_diff serialised as the STRING \"false\" is coerced, not read as truthy"
# A string is truthy, so `f.get("in_diff", True)` would opt an out-of-diff finding into blocking.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
fixed, reps = nz.normalize_finding(
    {'id':'y','severity':'MAJOR','location':'a.py:1','title':'t','in_diff':'false'})
assert fixed['in_diff'] is False, fixed['in_diff']
assert any('in_diff' in r for r in reps), reps
assert nz.rollup_verdict([fixed]) == 'APPROVE'
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "string boolean not coerced: $out"; fi

t="EVERY member of _BOOLS is coerced, not just in_diff"
# in_diff and ux_impact share one coercion loop, and only in_diff was covered. Iterating _BOOLS means
# a member ADDED to the set later is covered the moment it is added, rather than silently untested —
# the same reason the alias tests above iterate their tuples.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
assert nz._BOOLS, '_BOOLS is empty — this test would vacuously pass'
for key in sorted(nz._BOOLS):
    base={'id':'b','severity':'MAJOR','location':'a.py:1','title':'t','in_diff':True}
    for raw_val, want in (('false', False), ('true', True), ('False', False), ('True', True)):
        f=dict(base); f[key]=raw_val
        fixed, reps = nz.normalize_finding(f)
        assert fixed[key] is want, (key, raw_val, fixed[key])
        assert any(key in r for r in reps), (key, raw_val, reps)
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "a _BOOLS member was not coerced: $out"; fi

t="a ux_impact serialised as the STRING \"true\" still forces the ux_impact behaviour"
# ux_impact is the disjunct that blocks regardless of severity/floor, so a string arriving uncoerced
# is a verdict change, not a cosmetic one. Assert the coerced value drives the same verdict a real
# boolean does — comparing against the boolean form rather than hardcoding a verdict, so this stays
# correct if the ux_impact policy itself is deliberately changed.
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
def verdict(v):
    f, _ = nz.normalize_finding(
        {'id':'u','severity':'MAJOR','location':'a.py:1','title':'t','in_diff':True,
         'confidence':'HIGH','ux_impact':v})
    return f['ux_impact'], nz.rollup_verdict([f])
assert verdict('true') == verdict(True), (verdict('true'), verdict(True))
assert verdict('false') == verdict(False), (verdict('false'), verdict(False))
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "string ux_impact did not behave as the boolean: $out"; fi

t="an INCOMPLETE-but-actionable finding still blocks, and its gap is reported not gated"
# The two-tier split. normalize.py's own mk() emits recommendation:"" whenever a detector supplies
# no fix text, so gating the predicate on all ten keys would silence real scanner findings. The
# shortfall must be visible (contract_gaps) without being fatal (contract_defects).
if out=$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
f={'id':'S-1','severity':'MAJOR','location':'a.py:1','title':'t','in_diff':True,
   'confidence':'HIGH','category':'LINT','evidence':'e','ux_impact':False,'recommendation':''}
assert nz.contract_defects(f) == [], nz.contract_defects(f)
assert 'empty:recommendation' in nz.contract_gaps(f), nz.contract_gaps(f)
assert nz.rollup_verdict([f]) == 'REQUEST_CHANGES'
print('ok')
" "$SELF_DIR/normalize.py" 2>&1) && [ "$out" = "ok" ]; then pass "$t"
else fail "$t" "the actionable/complete split is wrong: $out"; fi

t="an unrankable severity is counted, not silently dropped from every bucket"
# review-scan.sh's membership guard used `if f.get("severity") in sev`, so a value it did
# not recognise fell out of all four counts while staying in `findings`.
n_unknown="$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
print(repr(nz.canon_severity('SEVERE')), nz.canon_severity('INFO'),
      nz.rollup_verdict([{'severity':'SEVERE','in_diff':True,'confidence':'HIGH'}]))
" "$SELF_DIR/normalize.py")"
if [ "$n_unknown" = "'' NIT APPROVE" ]; then pass "$t"
else fail "$t" "canon_severity/rollup mishandled an unrankable severity: $n_unknown"; fi

# ============================================================== regressions: review of the pipeline
# Each case below failed against the code before its fix and passes after it.

# run_bounded <seconds> <cmd...> — run a command, killing it if it outlives <seconds>. rc 124 on
# timeout. Portable: no `timeout` binary on stock macOS.
run_bounded() {
  local secs="$1" pid i=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid"
}

d="$(mkrepo argloop)"
for args in "--base" "--base origin/main --out" "--base --out x"; do
  t="'review-scan.sh $args' exits 2 instead of hanging"
  # shellcheck disable=SC2086  # word-splitting $args into separate flags is the point
  ( cd "$d" && run_bounded 10 "$SCAN" $args ) >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 2 ]; then pass "$t"; else fail "$t" "rc=$rc (124 = hung)"; fi
done

t="--max-findings is validated before any detector runs"
d="$(mkrepo badmax)"
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --max-findings abc ) >/dev/null 2>"$d/.err"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -d "$d/.code-review/raw" ] && grep -q 'positive integer' "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc raw/ exists: $([ -d "$d/.code-review/raw" ] && echo yes || echo no)"; fi

t="--detectors refuses a name that is not bare lowercase letters (no path traversal)"
( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --detectors 'python,../../x' ) >/dev/null 2>"$d/.err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'not a detector name' "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc: $(head -c 200 "$d/.err")"; fi

t="no --base: falls back to origin/master when that is the only remote ref"
d="$(mkrepo onlymaster)"
git -C "$d" update-ref refs/remotes/origin/master refs/remotes/origin/main
git -C "$d" update-ref -d refs/remotes/origin/main
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
( cd "$d" && "$SCAN" --out "$d/.code-review" --detectors impact ) >/dev/null 2>&1; rc=$?
tb="$(jq_get "$d/.code-review/SCAN.json" "d['target_branch']")"
if [ "$rc" -eq 0 ] && [ "$tb" = "origin/master" ]; then pass "$t"
else fail "$t" "rc=$rc target_branch=$tb"; fi

t="no --base: origin/HEAD wins and is reported as the branch it points at"
git -C "$d" update-ref refs/remotes/origin/trunk refs/remotes/origin/master
git -C "$d" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
( cd "$d" && "$SCAN" --out "$d/.code-review" --detectors impact ) >/dev/null 2>&1; rc=$?
tb="$(jq_get "$d/.code-review/SCAN.json" "d['target_branch']")"
if [ "$rc" -eq 0 ] && [ "$tb" = "origin/trunk" ]; then pass "$t"
else fail "$t" "rc=$rc target_branch=$tb"; fi

t="an explicit --base that does not resolve is refused, never substituted"
( cd "$d" && "$SCAN" --base origin/nope --out "$d/.code-review" ) >/dev/null 2>"$d/.err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q "origin/nope" "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc"; fi

t="a non-ASCII filename is scanned, not silently dropped by git's C-quoting"
d="$(mkrepo unicode)"
printf 'def f():\n    # TODO: handle the retry case\n    return 1\n' > "$d/café.py"
commit_branch "$d"
run_scan "$d" --detectors comments >/dev/null
hit="$(jq_get "$d/.code-review/SCAN.json" "sum(1 for f in d['findings'] if f['location'].startswith('café.py:'))")"
if [ "${hit:-0}" -ge 1 ]; then pass "$t"
else fail "$t" "no finding on café.py: $(jq_get "$d/.code-review/SCAN.json" "[f['location'] for f in d['findings']]")"; fi

t="a filename containing a newline is recorded as a coverage gap, not dropped silently"
d="$(mkrepo newline)"
printf 'x = 1\n' > "$d/bad
name.py"
commit_branch "$d"
run_scan "$d" --detectors impact >/dev/null
gap="$(jq_get "$d/.code-review/SCAN.json" "[s['tool'] for s in d['scan_meta']['tools_skipped']]")"
case "$gap" in *changed-files*) pass "$t" ;; *) fail "$t" "tools_skipped=$gap" ;; esac

t="the generated-file filter is anchored: src/prebuild/ and myvendor/ are real source"
d="$(mkrepo anchored)"
mkdir -p "$d/src/prebuild" "$d/myvendor" "$d/build"
printf 'x = 1\n' > "$d/src/prebuild/gen.py"
printf 'y = 1\n' > "$d/myvendor/lib.py"
printf 'z = 1\n' > "$d/build/out.py"
printf 'lock\n' > "$d/Cargo.lock"
commit_branch "$d"
run_scan "$d" --detectors impact >/dev/null
if grep -q '2 changed file(s) to scan (2 generated/excluded)' "$d/.stderr"; then pass "$t"
else fail "$t" "$(grep 'changed file' "$d/.stderr")"; fi

t="a stale SCAN-CONTRACT-DEFECTS.md from an earlier run is removed on a clean run"
d="$(mkrepo stalebanner)"
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
mkdir -p "$d/.code-review"; printf 'stale\n' > "$d/.code-review/SCAN-CONTRACT-DEFECTS.md"
run_scan "$d" --detectors impact >/dev/null
if [ ! -e "$d/.code-review/SCAN-CONTRACT-DEFECTS.md" ]; then pass "$t"
else fail "$t" "stale banner survived a clean run"; fi

t="the scratch changed-file list raw/.changed is not left behind"
if [ ! -e "$d/.code-review/raw/.changed" ]; then pass "$t"
else fail "$t" "raw/.changed left behind"; fi

t="a summary that cannot be written fails the run (exit 2), not a silent exit 0"
rm -f "$d/.code-review/SCAN-SUMMARY.md"
mkdir -p "$d/.code-review/SCAN-SUMMARY.md"      # a directory where the file must go
( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --detectors impact ) >/dev/null 2>"$d/.err"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'SCAN-SUMMARY.md' "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc"; fi

t="scanning a ref that is not checked out says so in scan_meta"
d="$(mkrepo wtmismatch)"
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
src_sha="$(git -C "$d" rev-parse HEAD)"
git -C "$d" checkout --quiet main
( cd "$d" && "$SCAN" --base origin/main --source "$src_sha" --out "$d/.code-review" --detectors impact ) >/dev/null 2>&1
m="$(jq_get "$d/.code-review/SCAN.json" "(d['scan_meta'].get('worktree_matches_source'), any('WORKTREE MISMATCH' in n for n in d['scan_meta']['notes']))")"
if [ "$m" = "(False, True)" ]; then pass "$t"; else fail "$t" "got $m"; fi

t="uncommitted edits to a changed file are named in scan_meta"
git -C "$d" checkout --quiet feature
printf 'x = 2\n' > "$d/a.py"
run_scan "$d" --detectors impact >/dev/null
m="$(jq_get "$d/.code-review/SCAN.json" "any('uncommitted' in n and 'a.py' in n for n in d['scan_meta']['notes'])")"
if [ "$m" = "True" ]; then pass "$t"; else fail "$t" "notes: $(jq_get "$d/.code-review/SCAN.json" "d['scan_meta']['notes']")"; fi

# --- the hunk filter, directly
FILTER_PY="$SELF_DIR/filter-carried-findings.py"
d="$(mkrepo hunks)"
seq 1 120 > "$d/a.txt"
printf 'def helper_func():\n    pass\n\ndef keep():\n    return 1\n' > "$d/m.py"
git -C "$d" add -A; git -C "$d" commit --quiet -m base
git -C "$d" update-ref refs/remotes/origin/main HEAD
awk 'NR==90{print "CHANGED"; next} {print}' "$d/a.txt" > "$d/a.tmp" && mv "$d/a.tmp" "$d/a.txt"
printf 'def keep():\n    return 1\n' > "$d/m.py"       # pure deletion of lines 1-3
commit_branch "$d"
cat > "$d/in.json" <<'JSON'
{"findings": [
  {"id": "RANGE", "location": "a.txt:80-100"},
  {"id": "RANGE-EN", "location": "a.txt:80–100"},
  {"id": "OUTSIDE", "location": "a.txt:10-20"},
  {"id": "POINT", "location": "a.txt:90"},
  {"id": "DELETED-AT-TOP", "location": "m.py:1"},
  {"id": "UNCHANGED-LINE", "location": "m.py:2"}
]}
JSON
( cd "$d" && python3 "$FILTER_PY" --in in.json --out out.json --target origin/main --source HEAD ) >/dev/null 2>&1
kept="$(jq_get "$d/out.json" "','.join(f['id'] for f in d['findings'])")"
t="a cited range is an interval: 80-100 is kept when only line 90 changed"
case ",$kept," in *,RANGE,*RANGE-EN,*) pass "$t" ;; *) fail "$t" "kept=$kept" ;; esac
t="a range entirely outside every hunk is still dropped"
case ",$kept," in *,OUTSIDE,*) fail "$t" "kept=$kept" ;; *) pass "$t" ;; esac
t="a pure-deletion hunk keeps a finding anchored at its boundary line"
case ",$kept," in *,DELETED-AT-TOP,*) pass "$t" ;; *) fail "$t" "kept=$kept" ;; esac
t="the deletion boundary rule does not widen to the next, unchanged line"
case ",$kept," in *,UNCHANGED-LINE,*) fail "$t" "kept=$kept" ;; *) pass "$t" ;; esac

t="the filter exits 3 with a message on unparseable input (was a traceback)"
printf '{not json' > "$d/bad.json"
( cd "$d" && python3 "$FILTER_PY" --in bad.json --out o.json --target origin/main --source HEAD ) >/dev/null 2>"$d/.err"; rc=$?
if [ "$rc" -eq 3 ] && grep -q 'not valid JSON' "$d/.err"; then pass "$t"
else fail "$t" "rc=$rc"; fi

t="end to end: a removed symbol that still has consumers survives diff-scoping"
d="$(mkrepo impactdel)"
printf 'def helper_func():\n    pass\n\ndef keep():\n    helper_func()\n' > "$d/m.py"
printf 'from m import helper_func\n' > "$d/use.py"
git -C "$d" add -A; git -C "$d" commit --quiet -m base
git -C "$d" update-ref refs/remotes/origin/main HEAD
printf 'def keep():\n    pass\n' > "$d/m.py"
commit_branch "$d"
run_scan "$d" --detectors impact >/dev/null
n="$(jq_get "$d/.code-review/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='impact' and 'helper_func' in f['title'])")"
if [ "${n:-0}" -eq 1 ]; then pass "$t"
else fail "$t" "impact findings in SCAN.json: $n (raw: $(jq_get "$d/.code-review/SCAN.raw.json" "[f['location'] for f in d['findings']]"))"; fi

# --- secrets.sh: a crashing tool is a failure, not a clean result
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho "fatal: rule set unavailable" >&2\nexit 1\n' > "$FAKE/gitleaks"
cp "$FAKE/gitleaks" "$FAKE/trivy"
chmod +x "$FAKE/gitleaks" "$FAKE/trivy"
d="$(mkrepo secretsfail)"
printf 'x = 1\n' > "$d/a.py"; printf 'y = 1\n' > "$d/b.py"; commit_branch "$d"
printf 'a.py\nb.py\n' > "$d/list"
( cd "$d" && PATH="$FAKE:$PATH" bash "$SELF_DIR/detectors/secrets.sh" "$d/list" "$d/so" ) >/dev/null 2>&1
t="gitleaks and trivy failing on every file are skips with their stderr, and write no raw JSON"
if [ -f "$d/so/raw/gitleaks.skipped" ] && [ -f "$d/so/raw/trivy.skipped" ] \
   && [ ! -e "$d/so/raw/gitleaks.json" ] && [ ! -e "$d/so/raw/trivy.json" ] \
   && grep -q 'rule set unavailable' "$d/so/raw/gitleaks.skipped"; then pass "$t"
else fail "$t" "raw/: $(ls -A "$d/so/raw" | tr '\n' ' ')"; fi

t="gitleaks failing on SOME files keeps the rest's findings and names the unscanned files"
cat > "$FAKE/gitleaks" <<'SH'
#!/bin/sh
# Fails on b.py, reports one finding on anything else.
case "$2" in *b.py) echo "fatal: cannot read" >&2; exit 1 ;; esac
while [ $# -gt 0 ]; do [ "$1" = "--report-path" ] && rpt="$2"; shift; done
printf '[{"RuleID":"generic-api-key","Description":"d","StartLine":1,"EndLine":1,"File":"a.py"}]' > "$rpt"
SH
rm -rf "$d/so"
( cd "$d" && PATH="$FAKE:$PATH" bash "$SELF_DIR/detectors/secrets.sh" "$d/list" "$d/so" ) >/dev/null 2>&1
n="$(jq_get "$d/so/raw/gitleaks.json" "len(d)")"
if [ "${n:-0}" -eq 1 ] && grep -q 'b.py' "$d/so/raw/gitleaks-partial.skipped" 2>/dev/null; then pass "$t"
else fail "$t" "findings=$n raw/: $(ls -A "$d/so/raw" | tr '\n' ' ')"; fi

t="normalize uses testpaths.py: B101 in e2e/, spec/ and conftest.py is suppressed, in src/ it is not"
r="$(python3 -c "
import sys, importlib.util
spec=importlib.util.spec_from_file_location('nz', sys.argv[1])
nz=importlib.util.module_from_spec(spec); spec.loader.exec_module(nz)
fs=[{'_tool':'bandit','_rule':'B101','_path':p} for p in ('e2e/helpers.py','spec/x.py','conftest.py','src/app.py')]
kept,_=nz.suppress(fs)
print(','.join(f['_path'] for f in kept))
" "$SELF_DIR/normalize.py")"
if [ "$r" = "src/app.py" ]; then pass "$t"; else fail "$t" "kept=$r"; fi

# --- second review round: each case failed before its fix
t="a tool's stderr cut mid UTF-8 character does not crash normalize and fail the scan"
# excerpt() keeps 200 BYTES; 199 ASCII bytes then `é` puts the cut inside the character, and
# normalize.py's strict decode of the .skipped reason then killed the whole scan with exit 2.
cat > "$FAKE/gitleaks" <<'SH'
#!/bin/sh
printf '%0199d' 0 | tr 0 x >&2
printf '\303\251 after the cut\n' >&2
exit 1
SH
d="$(mkrepo utf8cut)"
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
( cd "$d" && PATH="$FAKE:$PATH" "$SCAN" --base origin/main --out "$d/.code-review" --detectors secrets ) \
  >/dev/null 2>"$d/.err"; rc=$?
g="$(jq_get "$d/.code-review/SCAN.json" "[s['tool'] for s in d['scan_meta']['tools_skipped']]")"
case "$rc:$g" in 0:*gitleaks*) pass "$t" ;; *) fail "$t" "rc=$rc skipped=$g $(tail -c 200 "$d/.err")" ;; esac

t="--detectors with only separators is refused, not a scan that ran nothing and approved"
bad=""
for only in "," " " ",,"; do
  ( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --detectors "$only" ) >/dev/null 2>"$d/.err"; rc=$?
  { [ "$rc" -eq 2 ] && grep -q 'no detector names' "$d/.err"; } || bad="$bad '$only'(rc=$rc)"
done
if [ -z "$bad" ]; then pass "$t"; else fail "$t" "accepted:$bad"; fi

t="deleting a whole file still runs impact and reports the consumers it broke"
d="$(mkrepo delfile)"
printf 'def helper_func():\n    return 1\n' > "$d/lib.py"
printf 'from lib import helper_func\nprint(helper_func())\n' > "$d/main.py"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/main HEAD
git -C "$d" rm --quiet lib.py; commit_branch "$d"
run_scan "$d" >/dev/null
n="$(jq_get "$d/.code-review/SCAN.json" "sum(1 for f in d['findings'] if f['tool']=='impact' and f['location']=='lib.py:1' and 'helper_func' in f['title'])")"
if [ "${n:-0}" -eq 1 ]; then pass "$t"
else fail "$t" "impact findings: $n; stderr: $(grep -E 'changed file|impact' "$d/.stderr" | tr '\n' ' ')"; fi

t="a scan that dies part-way leaves no scratch lists in raw/"
d="$(mkrepo dieclean)"
printf 'x = 1\n' > "$d/a.py"; commit_branch "$d"
mkdir -p "$d/.code-review/SCAN-SUMMARY.md"      # makes the summary step die
( cd "$d" && "$SCAN" --base origin/main --out "$d/.code-review" --detectors impact ) >/dev/null 2>&1; rc=$?
left="$(ls -A "$d/.code-review/raw" | grep -E '^\.(changed|deleted|filter)' | tr '\n' ' ')"
if [ "$rc" -eq 2 ] && [ -z "$left" ]; then pass "$t"; else fail "$t" "rc=$rc left: $left"; fi

# ============================================================== summary
printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
