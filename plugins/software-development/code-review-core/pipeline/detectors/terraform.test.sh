#!/usr/bin/env bash
# terraform.test.sh — the IaC detector's own arms, below the generic contract.
#
#   bash pipeline/detectors/terraform.test.sh
#   zsh  pipeline/detectors/terraform.test.sh
#
# `detectors.test.sh` asserts the CONTRACT every detector shares (always exit 0, record every
# non-run, create raw/, write nothing outside it). This file asserts the three things specific to
# `terraform.sh`, none of which any other suite can see:
#
#   1. The DIRECTORY derivation. checkov and tfsec are directory-oriented — a single .tf file rarely
#      parses alone, because resources reference variables declared in sibling files — so the
#      detector scans the containing directories and lets the diff filter drop out-of-hunk hits. A
#      regression that passed file paths instead would produce "undefined variable" noise on a real
#      module and nothing at all on a one-file fixture, so the fixture here spans two directories.
#   2. The FMT SYNTHESIS. `terraform fmt -check` has no JSON mode; the detector manufactures one
#      tflint-shaped finding per misformatted file at line 1. It builds that document through a FILE
#      rather than an interpolated heredoc, so a filename containing a quote cannot be spliced into
#      the Python source — asserted below with exactly such a filename.
#   3. The TFLINT-ABSENT PROMOTE. `need tflint` failing skips the merge step that would otherwise
#      fold the fmt findings into raw/tflint.json, so they are promoted instead. Losing them would
#      be silent: a scan with no tflint would simply stop reporting a CI gate developers hit daily.
#
# Every case runs in a throwaway directory under $TMP, removed by the trap. No repository is touched
# and no network is used — `terraform init` is never run, by design.
#
# Portable bash 3.2+ / zsh.

set -uo pipefail
# No __pycache__ left in the plugin tree: the suites import normalize/contract/testpaths in place.
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DET="$SELF_DIR/terraform.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/terraform-detector-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

printf 'terraform detector tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

if [ ! -f "$DET" ]; then
  fail "detectors/terraform.sh exists" "not found at $DET"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

t="detectors/terraform.sh is executable"
# review-scan.sh invokes it as `bash "$script"`, so the bit is not strictly load-bearing there — but
# every sibling detector carries it, and a file that cannot be run directly is a trap for anyone
# debugging a scan by hand.
if [ -x "$DET" ]; then pass "$t"; else fail "$t" "the executable bit is not set"; fi

# run <workdir> <outdir> — invoke the detector the way review-scan.sh does: from the repo root, with
# a changed-file list holding repo-relative paths.
run() { ( cd "$1" && bash "$DET" "$1/.changed" "$2" ) >"$2.stdout" 2>"$2.stderr"; }

# ---------------------------------------------------------------- file-type selection
t="a diff with no IaC files records a skip and runs nothing"
wt="$TMP/noiac"; mkdir -p "$wt"
printf 'x = 1\n' > "$wt/app.py"
printf '%s\n' app.py > "$wt/.changed"
od="$TMP/out-noiac"; mkdir -p "$od"
run "$wt" "$od"
if [ -f "$od/raw/terraform.skipped" ] && grep -q 'no .tf' "$od/raw/terraform.skipped"; then
  pass "$t"
else
  fail "$t" "skip record: $(cat "$od/raw/terraform.skipped" 2>/dev/null || printf '<none>')"
fi

t="all three IaC extensions are selected (.tf, .tfvars, .hcl)"
# The extension list is a single `filter_ext` call, so a dropped extension is invisible unless each
# one is exercised. Asserted by the ABSENCE of the "no .tf/.tfvars/.hcl files" skip: whether any
# tool then produces a finding depends on which binaries are installed, but the selection does not.
missed=""
for ext in tf tfvars hcl; do
  wt="$TMP/ext-$ext"; mkdir -p "$wt"
  printf 'variable "v" {\n  type = string\n}\n' > "$wt/f.$ext"
  printf '%s\n' "f.$ext" > "$wt/.changed"
  od="$TMP/out-ext-$ext"; mkdir -p "$od"
  run "$wt" "$od"
  if [ -f "$od/raw/terraform.skipped" ] && grep -q 'no \.tf' "$od/raw/terraform.skipped"; then
    missed="$missed .$ext"
  fi
done
if [ -z "$missed" ]; then pass "$t"; else fail "$t" "these extensions were not selected:$missed"; fi

# ---------------------------------------------------------------- terraform fmt synthesis
if have terraform; then
  t="a misformatted .tf produces one synthesised terraform_fmt issue at line 1"
  wt="$TMP/fmt"; mkdir -p "$wt"
  printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "example-bucket"\n}\n' > "$wt/main.tf"
  printf '%s\n' main.tf > "$wt/.changed"
  od="$TMP/out-fmt"; mkdir -p "$od"
  run "$wt" "$od"
  # With tflint absent the fmt document is promoted to tflint.json; with tflint present it is merged
  # into the same file. Either way tflint.json is where a terraform_fmt issue lands.
  got="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print('no-file'); raise SystemExit
issues = [i for i in (d.get('issues') or []) if (i.get('rule') or {}).get('name') == 'terraform_fmt']
if not issues:
    print('none')
else:
    r = issues[0]['range']
    print(f\"{r['filename']}:{r['start']['line']}\")
" "$od/raw/tflint.json" 2>/dev/null)"
  if [ "$got" = "main.tf:1" ]; then
    pass "$t"
  else
    fail "$t" "expected main.tf:1, got '$got'"
  fi

  t="a terraform-fmt-clean file produces no terraform_fmt issue"
  # The false-positive direction. A detector emitting one issue per changed file regardless of
  # formatting would pass the case above and turn every IaC change into noise.
  wt="$TMP/fmtclean"; mkdir -p "$wt"
  printf 'resource "aws_s3_bucket" "b" {\n  bucket = "example-bucket"\n}\n' > "$wt/main.tf"
  printf '%s\n' main.tf > "$wt/.changed"
  od="$TMP/out-fmtclean"; mkdir -p "$od"
  run "$wt" "$od"
  n="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print(0); raise SystemExit
print(sum(1 for i in (d.get('issues') or [])
          if (i.get('rule') or {}).get('name') == 'terraform_fmt'))
" "$od/raw/tflint.json" 2>/dev/null)"
  if [ "${n:-0}" = "0" ]; then pass "$t"; else fail "$t" "$n terraform_fmt issue(s) on a clean file"; fi

  t="a filename containing a quote is not spliced into the synthesiser's Python source"
  # The reason the fmt step passes its file list through a FILE rather than an interpolated
  # heredoc, stated at the call site. A quote in a path would otherwise close the Python string and
  # execute whatever followed. The assertion is that the detector still exits 0 and still emits
  # valid JSON — i.e. the filename was DATA.
  wt="$TMP/fmtquote"; mkdir -p "$wt"
  odd="we'ird\".tf"
  printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "x"\n}\n' > "$wt/$odd"
  printf '%s\n' "$odd" > "$wt/.changed"
  od="$TMP/out-fmtquote"; mkdir -p "$od"
  run "$wt" "$od"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$t" "detector exited $rc on a quoted filename"
  elif [ -f "$od/raw/tflint.json" ] \
       && ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$od/raw/tflint.json" 2>/dev/null; then
    fail "$t" "raw/tflint.json is not valid JSON — the filename reached the source text"
  else
    pass "$t"
  fi
else
  skipt "terraform fmt synthesis tests" "terraform not installed"
fi

# ---------------------------------------------------------------- the tflint-absent promote
t="the synthesised fmt findings survive tflint being absent"
if ! have terraform; then
  skipt "$t" "terraform not installed, so there are no fmt findings to promote"
elif have tflint; then
  skipt "$t" "tflint is installed, so the promote branch is unreachable"
else
  # The barren-PATH trick is not used here: hiding `terraform` too would remove the very findings
  # whose survival is the point. This machine simply has no tflint, which IS the branch.
  wt="$TMP/promote"; mkdir -p "$wt"
  printf 'resource  "aws_s3_bucket" "b" {\n    bucket = "x"\n}\n' > "$wt/main.tf"
  printf '%s\n' main.tf > "$wt/.changed"
  od="$TMP/out-promote"; mkdir -p "$od"
  run "$wt" "$od"
  n="$(python3 -c "
import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get('issues') or []))
except (OSError, ValueError):
    print(0)
" "$od/raw/tflint.json" 2>/dev/null)"
  if [ "${n:-0}" -ge 1 ] && [ -f "$od/raw/tflint.skipped" ]; then
    pass "$t (promoted to raw/tflint.json, and the skip is still recorded)"
  elif [ "${n:-0}" -ge 1 ]; then
    fail "$t" "findings promoted but no tflint.skipped — the coverage gap is now invisible"
  else
    fail "$t" "raw/tflint.json holds ${n:-0} issue(s); the fmt findings were dropped"
  fi
fi

t="the scratch fmt document is not left behind as a phantom raw file"
# `tflint.fmt.json` is an intermediate. normalize.py has one tflint parser and no fmt parser, so a
# leftover would either be ignored (losing the findings) or, worse, be mistaken for a tool's output.
for od in "$TMP"/out-fmt "$TMP"/out-promote "$TMP"/out-fmtclean; do
  [ -d "$od/raw" ] || continue
  if [ -f "$od/raw/tflint.fmt.json" ]; then
    fail "$t" "$od/raw/tflint.fmt.json survived"
    left=yes
  fi
done
[ "${left:-no}" = "no" ] && pass "$t"

# ---------------------------------------------------------------- directory derivation
if have checkov; then
  t="IaC spread across two directories is scanned in BOTH"
  # The directory list is de-duplicated with `grep -qxF`, and a bug there (or a switch back to
  # per-file scanning) shows up as findings from only one of the two modules. Both fixtures are the
  # same world-open ingress rule, so "one directory reported" cannot be explained by the content.
  wt="$TMP/twodirs"; mkdir -p "$wt/mod-a" "$wt/mod-b"
  for m in mod-a mod-b; do
    cat > "$wt/$m/main.tf" <<'TF'
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
  done
  printf '%s\n' mod-a/main.tf mod-b/main.tf > "$wt/.changed"
  od="$TMP/out-twodirs"; mkdir -p "$od"
  run "$wt" "$od"
  dirs="$(python3 -c "
import json, os, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print(''); raise SystemExit
seen = set()
for c in (d.get('results') or {}).get('failed_checks') or []:
    p = c.get('file_abs_path') or c.get('file_path') or ''
    seen.add(os.path.basename(os.path.dirname(p)) or p)
print(','.join(sorted(x for x in seen if x)))
" "$od/raw/checkov.json" 2>/dev/null)"
  case "$dirs" in
    *mod-a*mod-b*) pass "$t (reported from: $dirs)" ;;
    "") skipt "$t" "this checkov build reports nothing on the fixture; the assertion would be vacuous" ;;
    *) fail "$t" "only these directories reported: '$dirs'" ;;
  esac

  t="the several concatenated checkov documents are decoded as a stream, not json.load'd"
  # One JSON document per `-d`, concatenated. A plain json.load on that raises "Extra data" with an
  # empty stderr, which read as a broken tool and silently dropped EVERY IaC security finding. The
  # two-directory fixture above is the shape that reproduces it; this asserts the output parses and
  # is non-empty, which a failed decode could not produce.
  if [ -f "$od/raw/checkov.json" ] \
     && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$od/raw/checkov.json" 2>/dev/null; then
    pass "$t"
  elif [ -f "$od/raw/checkov.skipped" ]; then
    skipt "$t" "checkov recorded a skip: $(head -1 "$od/raw/checkov.skipped")"
  else
    fail "$t" "raw/checkov.json is missing or unparseable"
  fi

  t="the scratch .checkov.parts stream is cleaned up"
  if [ ! -f "$od/raw/.checkov.parts" ]; then pass "$t"; else fail "$t" ".checkov.parts survived"; fi
else
  skipt "checkov directory-derivation tests" "checkov not installed"
fi

t="the scratch file list and directory list are cleaned up"
# `.tf-files` and `.tf-dirs` live under raw/, which normalize.py walks. A leftover is not fatal
# there, but it is exactly the kind of debris that makes a later `ls raw/` unreadable when someone
# is debugging a scan.
leftover=""
for od in "$TMP"/out-*; do
  [ -d "$od/raw" ] || continue
  [ -f "$od/raw/.tf-files" ] && leftover="$leftover ${od##*/}/.tf-files"
  [ -f "$od/raw/.tf-dirs" ] && leftover="$leftover ${od##*/}/.tf-dirs"
done
if [ -z "$leftover" ]; then pass "$t"; else fail "$t" "survived:$leftover"; fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
