#!/usr/bin/env bash
# deps.test.sh — the dependency-pinning detector's own arms, below the generic contract.
#
#   bash pipeline/detectors/deps.test.sh
#   zsh  pipeline/detectors/deps.test.sh
#
# `detectors.test.sh` asserts the CONTRACT every detector shares (always exit 0, record every
# non-run, create raw/, write nothing outside it). This file asserts what only `deps.sh` can be
# wrong about: whether each rule actually fires, and — the half that decides whether anyone leaves
# the detector switched on — whether a correctly pinned manifest produces NOTHING.
#
# THE NEGATIVE CASES ARE THE POINT. A detector that flags a correctly pinned dependency is worse
# than no detector: the first false positive costs a reviewer a minute, the tenth costs the detector
# its audience, and after that the real finding is in a list nobody reads. So every manifest type
# below is exercised twice — one fixture that MUST produce a finding, one correctly pinned fixture
# that MUST produce none — and the pairs are deliberately near-identical so a pass on the positive
# case cannot be explained by anything except the defect.
#
# The severity assertions are here for the same reason. `deps.sh` spreads its rules across MAJOR,
# MINOR and NIT on purpose (its header states the ladder); a regression that collapsed them onto one
# tier would leave every count above unchanged, so the tier is asserted alongside the rule id.
#
# Every fixture is built under $TMP and removed by the trap. No repository is touched, and nothing
# here reaches the network — which matters: "is this pinned" is decidable from the manifest text,
# and a detector that needed a registry to answer it would not belong in the zero-token stage.
#
# Portable bash 3.2+ / zsh.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DET="$SELF_DIR/deps.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/deps-detector-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

printf 'deps detector tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

if [ ! -f "$DET" ]; then
  fail "detectors/deps.sh exists" "not found at $DET"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 1
fi

# A missing python3 is a SKIP, never a pass: the detector itself records a skip in that case, and a
# suite that reported "ok" for a rule it never executed would be claiming coverage it does not have.
if ! have python3; then
  skipt "every deps.sh rule assertion" "python3 is not installed; the detector records its own skip"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

t="detectors/deps.sh is executable"
if [ -x "$DET" ]; then pass "$t"; else fail "$t" "the executable bit is not set"; fi

CASE=0

# run <workdir> — invoke the detector the way review-scan.sh does: from inside the tree, with a
# changed-file list of repo-relative paths. Prints the outdir.
run() {
  CASE=$((CASE + 1))
  local wt="$1" od="$TMP/out-$CASE"
  mkdir -p "$od"
  ( cd "$wt" && bash "$DET" "$wt/.changed" "$od" ) >"$od.stdout" 2>"$od.stderr"
  printf '%s\n' "$od"
}

# report <outdir> — every finding as "rule:severity", one per line. Empty when the detector found
# nothing, which is what the negative cases assert.
report() {
  python3 - "$1/raw/deps.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    raise SystemExit
for f in d.get("findings") or []:
    print(f"{f.get('rule')}:{f.get('severity')}")
PY
}

# expect_hit <label> <workdir> <rule:severity>
expect_hit() {
  local label="$1" wt="$2" want="$3" od got
  od="$(run "$wt")"
  got="$(report "$od" | tr '\n' ' ')"
  case " $got " in
    *" $want "*) pass "$label" ;;
    *) fail "$label" "expected a '$want' finding, got: ${got:-<none>}" ;;
  esac
}

# expect_clean <label> <workdir>
expect_clean() {
  local label="$1" wt="$2" od got
  od="$(run "$wt")"
  got="$(report "$od" | tr '\n' ' ')"
  if [ -z "${got// /}" ]; then
    pass "$label"
  else
    fail "$label" "a correctly pinned manifest produced: $got"
  fi
}

# fixture <name> <changed-file-path> — makes the directory and writes .changed; the caller writes
# the file contents.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/$(dirname "$2")"
  printf '%s\n' "$2" > "$d/.changed"
  printf '%s\n' "$d"
}

# ================================================================ GitHub Actions
# The rule with a real exploit path rather than a reproducibility argument, and the one that must
# agree with `github-workflow/skills/actions-authoring`. Three fixtures, because that skill states
# two exemptions and a detector that ignored them would contradict the document it implements.
d="$(fixture wf-bad .github/workflows/ci.yml)"
cat > "$d/.github/workflows/ci.yml" <<'YML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: some-org/some-action@main
YML
expect_hit "an action pinned to a tag is reported as MAJOR" "$d" "actions-unpinned-uses:MAJOR"

d="$(fixture wf-good .github/workflows/ci.yml)"
cat > "$d/.github/workflows/ci.yml" <<'YML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
      - uses: actions/setup-python@0b93645e9fea7318ecaed2b359559ac225c90a2b  # v5.3.0
      - run: pytest -q
YML
expect_clean "a SHA-pinned workflow produces nothing" "$d"

d="$(fixture wf-exempt .github/workflows/ci.yml)"
cat > "$d/.github/workflows/ci.yml" <<'YML'
name: ci
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/setup
      - uses: docker://alpine:3.19
      - uses: my-org/ci-workflows/.github/workflows/build.yml@v2
YML
expect_clean "actions-authoring's exemptions are honoured (local path, container action, reusable workflow)" "$d"

# ================================================================ Dockerfile
d="$(fixture docker-latest Dockerfile)"
printf 'FROM python:latest\nRUN pip install -r requirements.txt\n' > "$d/Dockerfile"
expect_hit "FROM <image>:latest is reported as MAJOR" "$d" "docker-base-latest:MAJOR"

d="$(fixture docker-untagged Dockerfile)"
printf 'FROM python\nRUN true\n' > "$d/Dockerfile"
expect_hit "FROM <image> with no tag is reported as MAJOR" "$d" "docker-base-untagged:MAJOR"

d="$(fixture docker-good Dockerfile)"
# Every shape the detector must NOT flag, in one file: a version tag, a digest, `scratch`, a
# multi-stage reference to an earlier stage, and a registry host carrying a PORT — that last one is
# the case where a naive "text after the last colon" tag parse reads `5000/app` as the tag.
cat > "$d/Dockerfile" <<'DOCKER'
FROM python:3.12-slim AS builder
RUN pip install --no-cache-dir .
FROM registry.example.com:5000/base:1.4.2 AS mid
FROM builder AS test
FROM gcr.io/distroless/python3@sha256:0000000000000000000000000000000000000000000000000000000000000000
FROM scratch
DOCKER
expect_clean "tagged, digest-pinned, scratch, stage-reference and registry-port bases produce nothing" "$d"

# ================================================================ requirements.txt
d="$(fixture req-bad requirements.txt)"
cat > "$d/requirements.txt" <<'REQ'
requests>=2.28
flask
REQ
expect_hit "a requirements.txt line without == is reported as MINOR" "$d" "python-unpinned-requirement:MINOR"

d="$(fixture req-editable requirements.txt)"
printf -- '-e git+https://example.com/org/lib@main#egg=lib\n' > "$d/requirements.txt"
expect_hit "an editable install from a branch is reported as MAJOR" "$d" "python-editable-mutable-ref:MAJOR"

d="$(fixture req-good requirements.txt)"
cat > "$d/requirements.txt" <<'REQ'
# generated by pip-compile
requests==2.31.0
flask==3.0.0
-r base.txt
--index-url https://pypi.org/simple
-e .
-e git+https://example.com/org/lib@11bd71901bbe5b1630ceea73d27597364c9af683#egg=lib
REQ
expect_clean "an exactly pinned requirements.txt produces nothing" "$d"

# ================================================================ pyproject.toml
d="$(fixture pyproj-bad pyproject.toml)"
cat > "$d/pyproject.toml" <<'TOML'
[project]
name = "demo"
requires-python = ">=3.10"
dependencies = [
  "requests>=2.28",
  "click",
]
TOML
expect_hit "a >=-only runtime dependency is reported as NIT" "$d" "python-dep-open-upper-bound:NIT"
d2="$(fixture pyproj-bad2 pyproject.toml)"
cp "$d/pyproject.toml" "$d2/pyproject.toml"
expect_hit "a dependency with no constraint at all is reported as MINOR" "$d2" "python-dep-unconstrained:MINOR"

d="$(fixture pyproj-good pyproject.toml)"
cat > "$d/pyproject.toml" <<'TOML'
[project]
name = "demo"
requires-python = ">=3.10"
dependencies = [
  "requests>=2.28,<3",
  "click==8.1.7",
  "rich~=13.7",
]

[project.optional-dependencies]
test = ["pytest"]

[tool.poetry.dependencies]
python = "^3.10"
httpx = "^0.27"
TOML
expect_clean "bounded ranges, an exact pin, ~= and a poetry caret produce nothing" "$d"

# ================================================================ package.json
d="$(fixture npm-bad package.json)"
cat > "$d/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": {
    "left-pad": "*"
  }
}
JSON
expect_hit "a runtime dependency accepting any version is reported as MAJOR" "$d" "npm-any-version:MAJOR"

d="$(fixture npm-caret package.json)"
cat > "$d/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": {
    "express": "^4.18.2"
  }
}
JSON
expect_hit "a caret range on a runtime dependency with no lockfile is reported as MINOR" "$d" "npm-range-loose:MINOR"

# The same manifest with a lockfile beside it. `npm ci` is reproducible there, so the finding drops
# to NIT rather than disappearing — the range still governs `npm install` and `npm update`. This is
# the assertion that stops the tier being quietly re-flattened.
d="$(fixture npm-caret-locked package.json)"
cat > "$d/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": {
    "express": "^4.18.2"
  }
}
JSON
printf '{"lockfileVersion": 3}\n' > "$d/package-lock.json"
expect_hit "the same caret range beside a lockfile drops to NIT" "$d" "npm-range-loose:NIT"

d="$(fixture npm-dev package.json)"
cat > "$d/package.json" <<'JSON'
{
  "name": "demo",
  "devDependencies": {
    "eslint": "^9.0.0"
  }
}
JSON
expect_hit "a caret range on a devDependency is a NIT" "$d" "npm-range-loose:NIT"

d="$(fixture npm-good package.json)"
cat > "$d/package.json" <<'JSON'
{
  "name": "demo",
  "dependencies": {
    "express": "4.18.2",
    "shared": "workspace:*",
    "local-lib": "file:../local-lib",
    "forked": "github:my-org/forked#11bd71901bbe5b1630ceea73d27597364c9af683"
  },
  "devDependencies": {
    "typescript": "5.7.2"
  }
}
JSON
expect_clean "exact versions, workspace/file protocols and a SHA-pinned git dependency produce nothing" "$d"

# ================================================================ .pre-commit-config.yaml
d="$(fixture pc-bad .pre-commit-config.yaml)"
cat > "$d/.pre-commit-config.yaml" <<'YML'
repos:
  - repo: https://github.com/psf/black
    rev: main
    hooks:
      - id: black
YML
expect_hit "a pre-commit rev on a branch is reported as MINOR" "$d" "precommit-rev-mutable:MINOR"

d="$(fixture pc-good .pre-commit-config.yaml)"
cat > "$d/.pre-commit-config.yaml" <<'YML'
repos:
  - repo: https://github.com/psf/black
    rev: 24.10.0
    hooks:
      - id: black
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: end-of-file-fixer
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: 11bd71901bbe5b1630ceea73d27597364c9af683
    hooks:
      - id: ruff
YML
expect_clean "version tags and a SHA rev produce nothing" "$d"

# ================================================================ selection and hygiene
t="a JSON file that is not a manifest is not scanned"
# `tsconfig.json` and `package.json` are both JSON in the same directory; only the second is a
# dependency manifest, and an extension-based filter cannot tell them apart. This is the assertion
# that the selection is by path shape.
d="$(fixture notamanifest tsconfig.json)"
printf '{"compilerOptions": {"strict": true}}\n' > "$d/tsconfig.json"
od="$(run "$d")"
if [ -f "$od/raw/deps.skipped" ] && grep -q 'no dependency manifest' "$od/raw/deps.skipped"; then
  pass "$t"
else
  fail "$t" "skip record: $(cat "$od/raw/deps.skipped" 2>/dev/null || printf '<none>')"
fi

t="a vendored manifest under node_modules is excluded"
# review-scan.sh filters generated trees before the detector sees them, but prepare-context.sh's
# --skip-scan path and a human debugging by hand do not, and one dependency tree would be thousands
# of findings about code nobody in this diff wrote.
d="$(fixture vendored node_modules/left-pad/package.json)"
printf '{"dependencies": {"x": "*"}}\n' > "$d/node_modules/left-pad/package.json"
od="$(run "$d")"
if [ -f "$od/raw/deps.skipped" ]; then
  pass "$t"
else
  fail "$t" "node_modules/left-pad/package.json was scanned: $(report "$od" | tr '\n' ' ')"
fi

t="a malformed package.json is a recorded note, not a crash and not a silent pass"
# A half-written manifest is a real state for a file under review. The detector must not report
# findings it could not compute, must not exit non-zero (the contract forbids it), and must not stay
# silent — a manifest that was never parsed reading as "nothing to flag" is the failure mode the
# whole skip-record clause exists to prevent, one level down.
d="$(fixture badjson package.json)"
printf '{ this is not json\n' > "$d/package.json"
od="$TMP/out-badjson"; mkdir -p "$od"
( cd "$d" && bash "$DET" "$d/.changed" "$od" ) >/dev/null 2>&1
rc=$?
notes="$(python3 -c "
import json, sys
try:
    print(' '.join(json.load(open(sys.argv[1])).get('notes') or []))
except (OSError, ValueError):
    pass
" "$od/raw/deps.json" 2>/dev/null)"
case "$rc:$notes" in
  0:*not\ parseable*) pass "$t" ;;
  *) fail "$t" "rc=$rc notes='$notes'" ;;
esac

t="the scratch file list is cleaned up"
# `.deps-files` lives under raw/, which normalize.py walks. A leftover is not fatal there, but it is
# the kind of debris that makes a later `ls raw/` unreadable when someone is debugging a scan.
leftover=""
for od in "$TMP"/out-*; do
  [ -d "$od/raw" ] || continue
  [ -f "$od/raw/.deps-files" ] && leftover="$leftover ${od##*/}/.deps-files"
done
if [ -z "$leftover" ]; then pass "$t"; else fail "$t" "survived:$leftover"; fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
