#!/usr/bin/env bash
# prepare-context.test.sh — tests for prepare-context.sh: flag handling, the diff budget, stack
# signal detection, the architect gate, and the shape of CONTEXT.json.
#
#   ./prepare-context.test.sh         # run everything
#   zsh ./prepare-context.test.sh     # the portability half of the contract
#
# Every test builds a THROWAWAY GIT REPO in a temp dir with a known diff. No network, no fixtures
# checked into the repo, nothing written outside $TMP.
#
# The scan is skipped (`--skip-scan`) in nearly every test: review-scan.sh has its own 35-case suite,
# and re-running eleven linters per fixture here would make this file take minutes and would couple
# these assertions to which binaries happen to be installed. Two tests exercise the wiring itself.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PREP="$SELF_DIR/prepare-context.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/prep-ctx-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# mkrepo <name> — repo with one commit on main plus a hand-written origin/main ref, then a branch.
# A real remote would need a network or a second clone; the base ref is all the script uses.
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init --quiet -b main
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  printf 'seed\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit --quiet -m seed
  git -C "$d" update-ref refs/remotes/origin/main HEAD
  git -C "$d" checkout --quiet -b feature
  printf '%s\n' "$d"
}

commit_branch() { git -C "$1" add -A; git -C "$1" commit --quiet -m change; }

# run_prep <repo> [args...] — run it, capture output, echo the out dir.
run_prep() {
  local d="$1"; shift
  ( cd "$d" && "$PREP" --base origin/main --out "$d/.code-review" --skip-scan "$@" \
      > "$d/.stdout" 2> "$d/.stderr" )
  printf '%s\n' "$d/.code-review"
}

get() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print($2)" "$1" 2>/dev/null; }

printf 'prepare-context tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

# ============================================================== argument handling
t="--base is required"
if ! "$PREP" >/dev/null 2>&1; then pass "$t"; else fail "$t" "exited 0 with no --base"; fi

t="unresolvable base ref exits non-zero"
d="$(mkrepo badbase)"
if ! ( cd "$d" && "$PREP" --base no/such/ref --out "$d/o" >/dev/null 2>&1 ); then
  pass "$t"
else fail "$t" "accepted a nonexistent base ref"; fi

t="unknown flag exits non-zero"
if ! "$PREP" --base HEAD --nope >/dev/null 2>&1; then pass "$t"; else fail "$t" "accepted --nope"; fi

t="invalid --effort is rejected"
d="$(mkrepo badeffort)"
if ! ( cd "$d" && "$PREP" --base origin/main --effort extreme >/dev/null 2>&1 ); then
  pass "$t"
else fail "$t" "accepted --effort extreme"; fi

t="--help prints usage and exits non-zero"
out="$("$PREP" --help 2>&1)"
case "$out" in *"usage: prepare-context.sh"*) pass "$t" ;; *) fail "$t" "no usage text" ;; esac

t="refuses to run outside a git repo"
mkdir -p "$TMP/notgit"
if ! ( cd "$TMP/notgit" && "$PREP" --base HEAD >/dev/null 2>&1 ); then
  pass "$t"
else fail "$t" "ran outside a repo"; fi

# ============================================================== empty diff
t="an empty diff yields changed_file_count 0, not a crash"
d="$(mkrepo emptydiff)"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['changed_file_count']")" = "0" ]; then
  pass "$t"
else fail "$t" "$(tail -3 "$d/.stderr" 2>/dev/null)"; fi

t="DIFF.md is written even for an empty diff"
if [ -s "$o/DIFF.md" ]; then pass "$t"; else fail "$t" "DIFF.md missing or empty"; fi

# ============================================================== signals
t="a python change sets signals.code"
d="$(mkrepo sigpy)"
printf 'def f():\n    return 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['signals']['code']")" = "True" ]; then pass "$t"
else fail "$t" "code signal not set"; fi

t="a markdown-only change sets signals.docs_only"
d="$(mkrepo sigdocs)"
printf '# guide\n\nprose\n' > "$d/GUIDE.md"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['signals']['docs_only']")" = "True" ]; then pass "$t"
else fail "$t" "docs_only not set"; fi

t="a mixed change is NOT docs_only"
d="$(mkrepo sigmixed)"
printf '# guide\n' > "$d/GUIDE.md"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['signals']['docs_only']")" = "False" ]; then pass "$t"
else fail "$t" "docs_only set on a mixed diff"; fi

t="a test file sets signals.tests"
d="$(mkrepo sigtests)"
mkdir -p "$d/tests"
printf 'def test_x():\n    assert True\n' > "$d/tests/test_x.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['signals']['tests']")" = "True" ]; then pass "$t"
else fail "$t" "tests signal not set"; fi

t="generated files are excluded from changed_files"
d="$(mkrepo genfiles)"
printf 'x = 1\n' > "$d/app.py"
printf '{"lockfileVersion": 3}\n' > "$d/package-lock.json"
commit_branch "$d"
o="$(run_prep "$d")"
n="$(get "$o/CONTEXT.json" "d['changed_file_count']")"
ex="$(get "$o/CONTEXT.json" "d['generated_excluded']")"
if [ "$n" = "1" ] && [ "$ex" = "1" ]; then pass "$t"
else fail "$t" "count=$n excluded=$ex (expected 1/1)"; fi

# ============================================================== architect gate
t="a plain code change does NOT spawn the architect"
d="$(mkrepo archplain)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a one-file python change"; fi

t="terraform in the diff DOES spawn the architect"
d="$(mkrepo archtf)"
printf 'variable "x" {\n  type = string\n}\n' > "$d/main.tf"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "IaC did not trigger the gate"; fi

t="a version-only manifest bump does NOT spawn the architect"
# The regression that motivated the rule: this repo mandates a plugin.json version bump on EVERY
# plugin edit, so matching the filename alone spawned the opus architect on every single change.
d="$(mkrepo archver)"
printf '{\n  "name": "p",\n  "version": "1.0.0"\n}\n' > "$d/plugin.json"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/main HEAD
printf '{\n  "name": "p",\n  "version": "1.1.0"\n}\n' > "$d/plugin.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['architect']['reason']")"; fi

t="a manifest change beyond the version DOES spawn the architect"
d="$(mkrepo archdep)"
printf '{\n  "name": "p",\n  "version": "1.0.0"\n}\n' > "$d/package.json"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/main HEAD
printf '{\n  "name": "p",\n  "version": "1.1.0",\n  "dependencies": {"left-pad": "1.0.0"}\n}\n' > "$d/package.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "a new dependency did not trigger the gate"; fi

t="a migration file DOES spawn the architect"
d="$(mkrepo archmig)"
mkdir -p "$d/migrations"
printf 'ALTER TABLE t ADD COLUMN c int;\n' > "$d/migrations/001_add.sql"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "migration did not trigger the gate"; fi

t="--effort low never spawns the architect, even on terraform"
d="$(mkrepo archlow)"
printf 'variable "x" {\n  type = string\n}\n' > "$d/main.tf"
commit_branch "$d"
o="$(run_prep "$d" --effort low)"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "--effort low spawned the architect"; fi

t="--effort high always spawns the architect, even on a docs-only diff"
d="$(mkrepo archhigh)"
printf '# doc\n' > "$d/D.md"
commit_branch "$d"
o="$(run_prep "$d" --effort high)"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "--effort high skipped the architect"; fi

t="the architect decision always carries a reason"
if [ -n "$(get "$o/CONTEXT.json" "d['architect']['reason']")" ]; then pass "$t"
else fail "$t" "empty reason"; fi

t="a docs-only diff does not spawn the architect at medium effort"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['architect']['spawn']")" = "False" ] \
   && [ "$(get "$o/CONTEXT.json" "d['architect']['reason']")" = "docs-only change" ]; then
  pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['architect']['reason']")"; fi

# ============================================================== testing gate
# The testing gate once shipped with ZERO assertions while the architect gate above had 27 — and
# the suite was green throughout. That is exactly the missing-case-in-an-enumeration defect the
# `review-testing` agent this gate spawns exists to catch, reproduced in the code that decides
# whether to spawn it. An enumerated gate needs an enumerated suite or the next branch added to it
# goes the same way.
#
# The four branches under test are prepare-context.sh:411-434: `--effort low`, `docs_only`, no
# non-test source, and spawn. The two language-convention cases below are assertions about
# testpaths.py's TEST_PATH union (`_test.[a-z]+$` and `.(test|spec).[a-z]+$`), which is what makes a
# `*_test.go`- or `*.spec.ts`-only diff a tests-only diff rather than production source.

t="a code change DOES spawn the testing pass"
d="$(mkrepo testcode)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="a test-only diff does NOT spawn the testing pass"
# No new production behaviour to judge the tests against, so the lens is vacuous.
d="$(mkrepo testonly)"
mkdir -p "$d/tests"
printf 'def test_x():\n    assert True\n' > "$d/tests/test_x.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a test-only diff"; fi

t="a test-only diff names ITSELF in the skip reason, not something else"
# The reason is the gate's audit trail; a docs-only diff reported as "tests-only"
# sends the next reader looking for tests that were never in the change.
if get "$o/CONTEXT.json" "d['testing']['reason']" | grep -q '^tests-only diff'; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="a docs-only diff does NOT spawn the testing pass"
d="$(mkrepo testdocs)"
printf '# doc\n' > "$d/README.md"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a docs-only diff"; fi

t="a go _test.go-only diff does NOT spawn the testing pass"
# Per-language convention, not just tests/. NOTE this one is covered by BOTH the old narrow regex and
# the union — see the union-only cases below for the ones that actually test what testpaths.py added.
d="$(mkrepo testgo)"
printf 'package p\n' > "$d/thing_test.go"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a *_test.go-only diff"; fi

t="a .spec.ts-only diff does NOT spawn the testing pass"
d="$(mkrepo testspec)"
printf 'it("x", () => {});\n' > "$d/app.spec.ts"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a .spec.ts-only diff"; fi

# ---- the three conventions the TEST_PATH UNION actually added ----
# The two cases above are `_test\.[a-z]+$` and `\.spec\.[a-z]+$`, and BOTH were already in the narrow
# regex testpaths.py replaced. So they assert ground that was never at risk, and the comment that used
# to call them "assertions about the TEST_PATH union" was false — green against the wrong subject.
# What the union added over the narrow spelling is exactly `e2e/`, `.test.<ext>` and therefore
# `*.test.sh`. The last matters most here: this catalog has ~40 `*.test.sh` files, and under the narrow
# regex every one of them counted as PRODUCTION source, so a suite-only diff spawned the testing pass
# against the tests themselves.
t="an e2e/-only diff does NOT spawn the testing pass (union-only: absent from the narrow regex)"
d="$(mkrepo teste2e)"
mkdir -p "$d/e2e"
printf 'export const flow = 1;\n' > "$d/e2e/flow.ts"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on an e2e/-only diff: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="a .test.ts-only diff does NOT spawn the testing pass (union-only)"
d="$(mkrepo testdotts)"
printf 'it("x", () => {});\n' > "$d/app.test.ts"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a .test.ts-only diff: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="a *.test.sh-only diff does NOT spawn the testing pass (union-only, ~40 such files here)"
d="$(mkrepo testdotsh)"
printf '#!/usr/bin/env bash\necho ok\n' > "$d/thing.test.sh"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a *.test.sh-only diff: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="source PLUS tests DOES spawn the testing pass"
# The common shape, and the one that matters most: the tests changed, so a reviewer
# must judge whether they changed ENOUGH for the source that changed with them.
d="$(mkrepo testboth)"
mkdir -p "$d/tests"
printf 'x = 1\n' > "$d/app.py"
printf 'def test_x():\n    assert True\n' > "$d/tests/test_x.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['testing']['reason']")"; fi

t="--effort low never spawns the testing pass, even on source"
d="$(mkrepo testlow)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d" --effort low)"
if [ "$(get "$o/CONTEXT.json" "d['testing']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "--effort low spawned the testing pass"; fi

# ========================================================== claude-config gate
# The fourth gate: fires when the diff touches SKILL.md, agents/*.md, .claude-plugin/plugin.json,
# or hooks/*.{json,sh}, so `review-authoring-conformance` can judge conformance to the Agent Skills
# open standard. Same {spawn, reason} shape and the same --effort low / docs-only exclusions as the
# architect and testing gates above.

t="a SKILL.md change DOES spawn the claude-config pass"
d="$(mkrepo cfgskill)"
mkdir -p "$d/plugins/example/skills/thing"
printf -- '---\nname: thing\n---\nbody\n' > "$d/plugins/example/skills/thing/SKILL.md"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="an agents/*.md change DOES spawn the claude-config pass"
d="$(mkrepo cfgagent)"
mkdir -p "$d/plugins/example/agents"
printf -- '---\nname: thing\n---\nbody\n' > "$d/plugins/example/agents/thing.md"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="a .claude-plugin/plugin.json change DOES spawn the claude-config pass"
d="$(mkrepo cfgplugin)"
mkdir -p "$d/plugins/example/.claude-plugin"
printf '{"name": "example", "version": "1.0.0"}\n' > "$d/plugins/example/.claude-plugin/plugin.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="a hooks/*.json change DOES spawn the claude-config pass"
d="$(mkrepo cfghooks)"
mkdir -p "$d/plugins/example/hooks"
printf '{"hooks": {}}\n' > "$d/plugins/example/hooks/hooks.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="a hooks/*.sh change DOES spawn the claude-config pass"
d="$(mkrepo cfghooksh)"
mkdir -p "$d/plugins/example/hooks"
printf '#!/usr/bin/env bash\necho ok\n' > "$d/plugins/example/hooks/pre-check.sh"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "True" ]; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="the claude-config decision names the changed file(s) in its reason"
if get "$o/CONTEXT.json" "d['claude_config']['reason']" | grep -q 'pre-check.sh'; then pass "$t"
else fail "$t" "reason: $(get "$o/CONTEXT.json" "d['claude_config']['reason']")"; fi

t="a plain code change does NOT spawn the claude-config pass"
d="$(mkrepo cfgcode)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a plain code change"; fi

t="a docs-only diff does NOT spawn the claude-config pass"
d="$(mkrepo cfgdocs)"
printf '# doc\n' > "$d/README.md"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "spawned on a docs-only diff"; fi

t="--effort low never spawns the claude-config pass, even on a SKILL.md change"
d="$(mkrepo cfglow)"
mkdir -p "$d/plugins/example/skills/thing"
printf -- '---\nname: thing\n---\nbody\n' > "$d/plugins/example/skills/thing/SKILL.md"
commit_branch "$d"
o="$(run_prep "$d" --effort low)"
if [ "$(get "$o/CONTEXT.json" "d['claude_config']['spawn']")" = "False" ]; then pass "$t"
else fail "$t" "--effort low spawned the claude-config pass"; fi

# ============================================================== diff budget
t="the total diff budget is never exceeded"
d="$(mkrepo budget)"
i=1
while [ "$i" -le 6 ]; do
  python3 -c "
import sys
with open(sys.argv[1], 'w') as fh:
    for n in range(400):
        fh.write(f'line {n} of file {sys.argv[2]}\n')" "$d/f$i.py" "$i"
  i=$((i + 1))
done
commit_branch "$d"
o="$(run_prep "$d" --max-diff-lines 300)"
used="$(get "$o/CONTEXT.json" "d['diff']['lines_included']")"
if [ -n "$used" ] && [ "$used" -le 300 ]; then pass "$t"
else fail "$t" "used $used of a 300-line budget"; fi

t="every file still appears when the budget is tight (per-file cap, not first-come)"
inc="$(get "$o/CONTEXT.json" "len(d['diff']['files_included'])")"
if [ "$inc" = "6" ]; then pass "$t"
else fail "$t" "only $inc of 6 files included — the budget was eaten by the first file"; fi

t="truncated files are named, not silently cut"
if [ "$(get "$o/CONTEXT.json" "len(d['diff']['files_truncated'])")" != "0" ]; then pass "$t"
else fail "$t" "nothing recorded as truncated despite a 300-line budget over 2400 lines"; fi

t="DIFF.md says how many lines it omitted"
if grep -q 'more diff line(s) omitted' "$o/DIFF.md"; then pass "$t"
else fail "$t" "no truncation marker in DIFF.md"; fi

t="--max-diff-files omits the overflow and records it"
d="$(mkrepo maxfiles)"
i=1
while [ "$i" -le 5 ]; do printf 'x = %s\n' "$i" > "$d/g$i.py"; i=$((i + 1)); done
commit_branch "$d"
o="$(run_prep "$d" --max-diff-files 2)"
inc="$(get "$o/CONTEXT.json" "len(d['diff']['files_included'])")"
om="$(get "$o/CONTEXT.json" "len(d['diff']['files_omitted'])")"
if [ "$inc" = "2" ] && [ "$om" = "3" ]; then pass "$t"
else fail "$t" "included=$inc omitted=$om (expected 2/3)"; fi

t="omitted files are named in DIFF.md"
if grep -q 'NOT below' "$o/DIFF.md"; then pass "$t"
else fail "$t" "no omission notice in DIFF.md"; fi

t="source files get the budget before prose"
# 1 python file + 4 markdown files, budget too small for all of them at full size. The python diff
# must come back whole; markdown is what gets squeezed.
d="$(mkrepo prio)"
python3 -c "
import sys
with open(sys.argv[1], 'w') as fh:
    for n in range(70):
        fh.write(f'v{n} = {n}\n')" "$d/code.py"
i=1
while [ "$i" -le 4 ]; do
  python3 -c "
import sys
with open(sys.argv[1], 'w') as fh:
    for n in range(200):
        fh.write(f'prose line {n}\n')" "$d/doc$i.md"
  i=$((i + 1))
done
commit_branch "$d"
o="$(run_prep "$d" --max-diff-lines 400)"
if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if 'code.py' not in d['diff']['files_truncated'] else 1)" "$o/CONTEXT.json"; then
  pass "$t"
else fail "$t" "code.py was truncated while markdown kept its share"; fi

t="DIFF.md is byte-identical across two runs of the same diff"
o2="$(run_prep "$d" --max-diff-lines 400)"
if cmp -s "$o/DIFF.md" "$o2/DIFF.md"; then pass "$t"
else fail "$t" "output is not deterministic"; fi

# ============================================================== per-line byte cap
t="a single oversized diff line is truncated, not left to blow up DIFF.md's byte size"
d="$(mkrepo hugeline)"
python3 -c "
import sys
with open(sys.argv[1], 'w') as fh:
    fh.write('x' * 900000 + '\n')" "$d/big.svg"
commit_branch "$d"
o="$(run_prep "$d")"
bytes_out="$(wc -c < "$o/DIFF.md" | tr -d '[:space:]')"
if [ "$bytes_out" -lt 100000 ]; then pass "$t"
else fail "$t" "DIFF.md is $bytes_out bytes — a 900000-char line sailed through uncapped"; fi

t="the truncation marker names the original line length"
if grep -q 'TRUNCATED: line was 900001 chars' "$o/DIFF.md"; then pass "$t"
else fail "$t" "no length-naming truncation marker in DIFF.md"; fi

# NOTE: never name a local var "path" — zsh ties the lowercase scalar "path" to $PATH (kept in
# sync as a colon-split array), so `path="$(...)"` silently REWRITES $PATH for the rest of the
# script under zsh, and every command after it starts failing with "command not found". Learned
# the hard way while adding this very test.
t="CONTEXT.json records exactly one byte-truncated line, for the right file"
n="$(get "$o/CONTEXT.json" "len(d['diff']['lines_byte_truncated'])")"
svg_path="$(get "$o/CONTEXT.json" "d['diff']['lines_byte_truncated'][0]['path'] if d['diff']['lines_byte_truncated'] else ''")"
cnt="$(get "$o/CONTEXT.json" "d['diff']['lines_byte_truncated'][0]['count'] if d['diff']['lines_byte_truncated'] else -1")"
if [ "$n" = "1" ] && [ "$svg_path" = "big.svg" ] && [ "$cnt" = "1" ]; then pass "$t"
else fail "$t" "entries=$n path=$svg_path count=$cnt"; fi

t="a byte-truncated file is NOT also reported as files_truncated (different mechanism)"
if [ "$(get "$o/CONTEXT.json" "'big.svg' in d['diff']['files_truncated']")" = "False" ]; then pass "$t"
else fail "$t" "big.svg wrongly appeared in files_truncated (that's the line-count mechanism)"; fi

t="the byte cap preserves line count: same number of lines as the raw git diff"
raw_count="$(git -C "$d" diff --no-color -U3 origin/main...feature -- big.svg | wc -l | tr -d '[:space:]')"
# big.svg is the only file in this repo's diff, so the first fenced block IS its whole body.
body_count="$(awk '/^```diff$/{f=1;next} f && /^```$/{exit} f{c++} END{print c+0}' "$o/DIFF.md")"
if [ "$body_count" = "$raw_count" ]; then pass "$t"
else fail "$t" "raw git diff has $raw_count line(s), DIFF.md's rendered body has $body_count"; fi

t="a byte-truncated line and a per-file line-count omission can coexist without corrupting rendering"
d="$(mkrepo dualcap)"
python3 -c "
import sys
lines = []
for n in range(200):
    lines.append(('y' * 5000) if n == 10 else f'line {n}')
with open(sys.argv[1], 'w') as fh:
    fh.write(chr(10).join(lines) + chr(10))" "$d/wide.py"
commit_branch "$d"
o="$(run_prep "$d" --max-diff-lines 60)"
in_trunc="$(get "$o/CONTEXT.json" "'wide.py' in d['diff']['files_truncated']")"
n_byte="$(get "$o/CONTEXT.json" "len(d['diff']['lines_byte_truncated'])")"
if [ "$in_trunc" = "True" ] && [ "$n_byte" = "1" ]; then pass "$t"
else fail "$t" "files_truncated has wide.py=$in_trunc, lines_byte_truncated entries=$n_byte"; fi

t="both markers render distinctly in DIFF.md without garbling one another"
if grep -q 'TRUNCATED: line was' "$o/DIFF.md" && grep -q 'more diff line(s) omitted' "$o/DIFF.md"; then
  pass "$t"
else fail "$t" "expected both a byte-truncation marker and a line-omission marker in DIFF.md"; fi

# ============================================================== contract shape
t="CONTEXT.json carries every field the skill and the agents read"
d="$(mkrepo shape)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
missing="$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
need = ['source_branch','target_branch','base_ref','source_ref','reviewed_sha','diff_range',
        'effort','changed_files','changed_file_count','generated_excluded','signals','diff',
        'architect','invariants_path','invariants_reason','scan','worktree']
print(','.join(k for k in need if k not in d))" "$o/CONTEXT.json")"
if [ -z "$missing" ]; then pass "$t"; else fail "$t" "missing: $missing"; fi

t="reviewed_sha is the source ref's SHA, not necessarily local HEAD"
want="$(git -C "$d" rev-parse HEAD)"
if [ "$(get "$o/CONTEXT.json" "d['reviewed_sha']")" = "$want" ]; then pass "$t"
else fail "$t" "sha mismatch"; fi

# The semantic agent has no Bash, so Read/Grep see the working tree and it cannot ask git for a
# ref. These two assert the flag it branches on: reviewing a pushed branch means diffing
# origin/<branch> WITHOUT checking it out, so "the working tree is the reviewed commit" is an
# assumption, not a fact.
t="worktree.matches_reviewed_ref is true when the source ref IS checked out"
if [ "$(get "$o/CONTEXT.json" "d['worktree']['matches_reviewed_ref']")" = "True" ] \
   && [ "$(get "$o/CONTEXT.json" "d['worktree']['head_sha']")" = "$want" ]; then pass "$t"
else fail "$t" "got matches=$(get "$o/CONTEXT.json" "d['worktree']['matches_reviewed_ref']")"; fi

t="target_branch has the origin/ prefix stripped"
if [ "$(get "$o/CONTEXT.json" "d['target_branch']")" = "main" ]; then pass "$t"
else fail "$t" "got $(get "$o/CONTEXT.json" "d['target_branch']")"; fi

t="--skip-scan records the scan as absent rather than implying it was clean"
if [ "$(get "$o/CONTEXT.json" "d['scan']['present']")" = "False" ]; then pass "$t"
else fail "$t" "scan reported present with --skip-scan"; fi

t="invariants_path is null when .claude-invariants.json is absent"
if [ "$(get "$o/CONTEXT.json" "d['invariants_path']")" = "None" ]; then pass "$t"
else fail "$t" "got $(get "$o/CONTEXT.json" "d['invariants_path']")"; fi

t="worktree.matches_reviewed_ref is FALSE when reviewing a ref that is not checked out"
# Mirrors the real pushed-branch case: origin/<branch> holds a commit the checked-out tree does
# not, and nothing checks it out. DIFF.md is built from the ref; Read/Grep would see the other
# commit.
d="$(mkrepo unchecked)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
git -C "$d" branch --quiet other
printf 'y = 2\n' > "$d/app.py"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/other "$(git -C "$d" rev-parse other)"
uo="$(run_prep "$d" --source origin/other)"
head_sha="$(git -C "$d" rev-parse HEAD)"
other_sha="$(git -C "$d" rev-parse other)"
if [ "$(get "$uo/CONTEXT.json" "d['worktree']['matches_reviewed_ref']")" = "False" ] \
   && [ "$(get "$uo/CONTEXT.json" "d['worktree']['head_sha']")" = "$head_sha" ] \
   && [ "$(get "$uo/CONTEXT.json" "d['reviewed_sha']")" = "$other_sha" ]; then pass "$t"
else fail "$t" "matches=$(get "$uo/CONTEXT.json" "d['worktree']['matches_reviewed_ref']") \
head=$(get "$uo/CONTEXT.json" "d['worktree']['head_sha']") want $head_sha"; fi

t="the stale-worktree case is reported on stdout, not only in the JSON"
if grep -q 'working tree is at' "$d/.stdout" 2>/dev/null; then pass "$t"
else fail "$t" "no warning in stdout: $(tail -2 "$d/.stdout" 2>/dev/null)"; fi

t="invariants_path is set when the file exists"
d="$(mkrepo inv)"
printf 'x = 1\n' > "$d/app.py"
printf '{"invariants": []}\n' > "$d/.claude-invariants.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['invariants_path']")" = ".claude-invariants.json" ]; then pass "$t"
else fail "$t" "got $(get "$o/CONTEXT.json" "d['invariants_path']")"; fi

t="an in-cap invariants file records WHY it was advertised, with its byte count"
reason="$(get "$o/CONTEXT.json" "d['invariants_reason']")"
case "$reason" in
  advertised:*"byte cap") pass "$t" ;;
  *) fail "$t" "got $reason" ;;
esac

# `.claude-invariants.json` is repo-authored, so an oversized one is an unbounded prompt-injection
# surface AND an unbounded cache-write bill. The cap is refuse-to-ADVERTISE rather than truncate,
# because prepare-context.sh writes only the path and the agent opens the file itself: a truncated
# copy would never be the copy that gets read. These two assertions are the pair that matters —
# the path must go null, AND the reason must say it was refused, because a null path with no reason
# is indistinguishable from a repo that has no invariants file at all.
t="an oversized .claude-invariants.json is NOT advertised"
d="$(mkrepo invbig)"
printf 'x = 1\n' > "$d/app.py"
python3 -c "
import json, sys
json.dump({'invariants': [{'id': 'PAD', 'rule': 'x' * 9000}]}, open(sys.argv[1], 'w'))
" "$d/.claude-invariants.json"
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['invariants_path']")" = "None" ]; then pass "$t"
else fail "$t" "advertised a $(wc -c < "$d/.claude-invariants.json" | tr -d '[:space:]')-byte file"; fi

t="the refusal is recorded as a reason, not as a silent null"
reason="$(get "$o/CONTEXT.json" "d['invariants_reason']")"
case "$reason" in
  *"NOT advertised"*"exceeds"*) pass "$t" ;;
  *) fail "$t" "got $reason" ;;
esac

t="the refusal is announced on stderr too, so a CI log shows the check was skipped"
if grep -q 'NOT advertising it to the agents' "$d/.stderr" 2>/dev/null; then pass "$t"
else fail "$t" "no warning in stderr: $(tail -2 "$d/.stderr" 2>/dev/null)"; fi

t="invariants_reason distinguishes absent from refused"
d="$(mkrepo invnone)"
printf 'x = 1\n' > "$d/app.py"
commit_branch "$d"
o="$(run_prep "$d")"
case "$(get "$o/CONTEXT.json" "d['invariants_reason']")" in
  absent:*) pass "$t" ;;
  *) fail "$t" "got $(get "$o/CONTEXT.json" "d['invariants_reason']")" ;;
esac

t="a renamed file is reported at its new path"
d="$(mkrepo renamed)"
printf 'x = 1\n' > "$d/old.py"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/main HEAD
git -C "$d" mv old.py new.py
commit_branch "$d"
o="$(run_prep "$d")"
if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if 'new.py' in d['changed_files'] else 1)" "$o/CONTEXT.json"; then
  pass "$t"
else fail "$t" "changed_files: $(get "$o/CONTEXT.json" "d['changed_files']")"; fi

t="a deleted file is not offered for review"
d="$(mkrepo deleted)"
printf 'x = 1\n' > "$d/gone.py"
commit_branch "$d"
git -C "$d" update-ref refs/remotes/origin/main HEAD
git -C "$d" rm --quiet gone.py
commit_branch "$d"
o="$(run_prep "$d")"
if [ "$(get "$o/CONTEXT.json" "d['changed_file_count']")" = "0" ]; then pass "$t"
else fail "$t" "a deleted file reached changed_files"; fi

t="the scratch changed-file list is cleaned up"
if [ ! -f "$o/.changed" ] && [ ! -f "$o/.changed.all" ]; then pass "$t"
else fail "$t" "left scratch files in the out dir"; fi

# ============================================================== scanner wiring
t="without --skip-scan the scanner runs and SCAN.json is ingested"
if ! have python3; then
  skipt "$t" "python3 absent"
else
  d="$(mkrepo wiring)"
  printf 'x = 1\n' > "$d/app.py"
  commit_branch "$d"
  ( cd "$d" && "$PREP" --base origin/main --out "$d/.code-review" --quiet \
      > "$d/.stdout" 2> "$d/.stderr" )
  if [ "$(get "$d/.code-review/CONTEXT.json" "d['scan']['present']")" = "True" ] \
     && [ -f "$d/.code-review/SCAN.json" ]; then
    pass "$t"
  else fail "$t" "$(tail -3 "$d/.stderr" 2>/dev/null)"; fi

  t="the ingested scan metrics match SCAN.json itself"
  a="$(get "$d/.code-review/CONTEXT.json" "d['scan']['metrics']['total']")"
  b="$(get "$d/.code-review/SCAN.json" "d['metrics']['total']")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then pass "$t"
  else fail "$t" "context says $a, SCAN.json says $b"; fi

  t="the skipped-detector list is carried into CONTEXT.json"
  # Names only — the reasons stay in SCAN-SUMMARY.md. A caller must be able to print the coverage
  # gaps from CONTEXT.json alone, because that is what the verdict line does.
  if python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if isinstance(d['scan']['tools_skipped'], list) else 1)" "$d/.code-review/CONTEXT.json"; then
    pass "$t"
  else fail "$t" "tools_skipped is not a list"; fi
fi

# ============================================================== ADR-004 artifact fencing
# The FOURTH sibling implementation of the same decision. Three of the four now assert these
# properties; this was the one still relying on someone remembering. Same three assertions
# throughout, deliberately: a decision implemented in four places needs the same test in four
# places, or "it is tested" becomes true of the codebase and false of the site you are editing.
d=$(mkrepo fence)
printf 'x = 2\n' >> "$d/a.py"; commit_branch "$d"
OUTD=$(run_prep "$d")

t="prepare-context fences its artifact dir with a '*' .gitignore"
if [ -f "$OUTD/.gitignore" ] && [ "$(cat "$OUTD/.gitignore")" = "*" ]; then pass "$t"
else fail "$t" "got: $(cat "$OUTD/.gitignore" 2>/dev/null || echo '<absent>')"; fi

t="the fence ignores nested artifacts recursively"
# The property that makes ONE file at the artifact root sufficient. Asked of git, not asserted.
mkdir -p "$OUTD/nested"; : > "$OUTD/nested/CONTEXT.json"
if git -C "$d" check-ignore -q ".code-review/nested/CONTEXT.json"; then pass "$t"
else fail "$t" "a nested artifact was not ignored"; fi

t="a user-edited .gitignore is preserved, not clobbered"
# prepare-context runs on every review, so a guardless write would silently revert a deliberate
# local narrowing on the next run and the documented escape hatch would not hold either.
d2=$(mkrepo fence2)
printf 'y = 3\n' >> "$d2/a.py"; commit_branch "$d2"
mkdir -p "$d2/.code-review"
printf '# narrowed by a human\n*.json\n' > "$d2/.code-review/.gitignore"
run_prep "$d2" >/dev/null
if grep -q 'narrowed by a human' "$d2/.code-review/.gitignore"; then pass "$t"
else fail "$t" "prepare-context clobbered a user-edited fence"; fi

# ============================================================== summary
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
