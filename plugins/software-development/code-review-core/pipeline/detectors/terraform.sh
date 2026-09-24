#!/usr/bin/env bash
# terraform.sh — fmt, tflint, checkov, tfsec over the changed .tf/.tfvars/.hcl files.
#
# `terraform validate` is NOT run: it requires `terraform init`, which needs backend credentials
# and provider downloads. A review scan must never authenticate anywhere — it is an advisory read of
# a diff — and a local init against a dev backend still costs seconds of network for little review
# value. fmt + tflint + checkov + tfsec are all offline and need no init.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"
TF="$RAW/.tf-files"
filter_ext "$LIST" .tf .tfvars .hcl > "$TF"

if ! any_lines "$TF"; then
  skip "terraform" "no .tf/.tfvars/.hcl files in the diff"
  # Scratch files live under raw/, which is where normalize.py looks, so the early exit cleans up
  # after itself rather than leaving an empty `.tf-files` behind for someone debugging a scan.
  rm -f "$TF" 2>/dev/null
  exit 0
fi

set --
while IFS= read -r f; do
  [ -n "$f" ] && set -- "$@" "$f"
done < "$TF"

# The directories containing changed IaC. checkov and tfsec are directory-oriented: a single .tf
# file rarely parses on its own because resources reference variables and locals declared in
# sibling files, so scanning the file alone produces spurious "undefined variable" noise. Scanning
# the containing directory and letting the diff filter drop out-of-hunk findings is both more
# accurate and no more expensive.
DIRS="$RAW/.tf-dirs"
: > "$DIRS"
for f in "$@"; do
  d="$(dirname "$f")"
  grep -qxF "$d" "$DIRS" 2>/dev/null || printf '%s\n' "$d" >> "$DIRS"
done

if need terraform; then
  # `fmt -check` lists misformatted files on stdout and exits non-zero; there is no JSON mode, so
  # synthesise one finding per file at line 1. Cheap, deterministic, and it is a real CI gate
  # (terraform:fmt) that developers hit constantly.
  # Via a file, not an interpolated heredoc: a filename containing a quote would otherwise be
  # spliced straight into the Python source.
  terraform fmt -check -no-color "$@" > "$RAW/.fmt-out" 2>/dev/null
  python3 - "$RAW/.fmt-out" "$RAW/tflint.fmt.json" <<'PY'
import json, sys
files = [l.strip() for l in open(sys.argv[1]).read().splitlines() if l.strip()]
issues = [{
    "rule": {"name": "terraform_fmt", "severity": "warning",
             "link": "https://developer.hashicorp.com/terraform/cli/commands/fmt"},
    "message": "File is not terraform-fmt clean; the terraform:fmt CI job will fail.",
    "range": {"filename": f, "start": {"line": 1}, "end": {"line": 1}},
} for f in files]
json.dump({"issues": issues, "errors": []}, open(sys.argv[2], "w"))
PY
  note "terraform-fmt" "$(grep -c '[^[:space:]]' "$RAW/.fmt-out" || true) unformatted file(s)"
else
  skip "terraform-fmt" "terraform binary not found on PATH"
fi

if need tflint; then
  # tflint dropped positional file arguments in v0.47 — it is now --chdir plus --filter, and
  # passing paths gives "Command line arguments support was dropped in v0.47" in `.errors` with an
  # empty `.issues`, i.e. a silent zero-finding scan. Run it once per directory with --filter.
  : > "$RAW/.tflint.parts"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    set --
    while IFS= read -r f; do
      case "$(dirname "$f")" in "$d") set -- "$@" "--filter=$(basename "$f")" ;; esac
    done < "$TF"
    [ $# -gt 0 ] || continue
    ( cd "$d" && tflint --format=json --force "$@" ) >> "$RAW/.tflint.parts" 2>/dev/null
  done < "$DIRS"
  # Merge the per-directory documents, re-rooting each filename to repo-relative: tflint reports
  # paths relative to its --chdir, so without this every location would be a bare basename and
  # would never match a diff hunk.
  if python3 - "$RAW/.tflint.parts" "$DIRS" "$RAW/tflint.json" "$RAW/tflint.fmt.json" <<'PY'
import json, os, sys
parts_path, dirs_path, out_path, fmt_path = sys.argv[1:5]
dirs = [d.strip() for d in open(dirs_path).read().splitlines() if d.strip()] if os.path.exists(dirs_path) else []
issues, errors = [], []
# Each `tflint --format=json` run emits one complete JSON document; concatenating them gives a
# stream, so decode incrementally rather than with a single json.load.
try:
    buf = open(parts_path).read()
except OSError:
    buf = ""
dec, idx, seen = json.JSONDecoder(), 0, 0
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    try:
        doc, idx = dec.raw_decode(buf, idx)
    except ValueError:
        break
    base = dirs[seen] if seen < len(dirs) else "."
    seen += 1
    for i in doc.get("issues") or []:
        rng = i.get("range") or {}
        fn = rng.get("filename") or ""
        if fn and not os.path.isabs(fn):
            rng["filename"] = os.path.normpath(os.path.join(base, fn))
        i["range"] = rng
        issues.append(i)
    errors.extend(doc.get("errors") or [])
# Fold the synthesised terraform-fmt findings into the same document — normalize.py has one tflint
# parser and there is no reason for two.
if os.path.exists(fmt_path):
    try:
        issues.extend(json.load(open(fmt_path)).get("issues") or [])
    except ValueError:
        pass
json.dump({"issues": issues, "errors": errors}, open(out_path, "w"))
PY
  then
    note tflint "ok"
  else
    skip "tflint" "could not merge per-directory output"
  fi
  rm -f "$RAW/.tflint.parts" "$RAW/tflint.fmt.json"
else
  # tflint is absent but the fmt findings may still exist — promote them so they are not lost.
  [ -f "$RAW/tflint.fmt.json" ] && mv "$RAW/tflint.fmt.json" "$RAW/tflint.json"
  skip "tflint" "binary not found on PATH"
fi

if need checkov; then
  # ONE INVOCATION PER DIRECTORY, not one invocation carrying several `-d` flags.
  #
  # Measured against checkov 3.2.x: `checkov -d mod-a -d mod-b` emits two documents whose
  # `failed_checks` ACCUMULATE (4 then 8) and whose `file_abs_path` names the FIRST directory for
  # every single check — so mod-b's findings arrive attributed to mod-a/main.tf. Downstream that is
  # worse than losing them: normalize.py anchors the finding on the path checkov gave, and the
  # diff filter then either drops it as out-of-hunk or, if the two modules happen to have changed
  # on the same line numbers, reports a violation against a file that does not contain it.
  #
  # The loop costs one process per changed IaC directory, which is bounded by the diff.
  : > "$RAW/.checkov.parts"
  : > "$RAW/.checkov.err"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # --compact drops the code blocks (we read evidence off disk ourselves); --quiet drops the
    # banner. checkov exits 1 when a check fails, so judge by whether the output parses.
    checkov -d "$d" --output json --compact --quiet --framework terraform \
      >> "$RAW/.checkov.parts" 2>> "$RAW/.checkov.err"
  done < "$DIRS"
  # The per-directory documents are CONCATENATED, so the buffer is a JSON stream, not a document. A
  # plain json.load on that fails with "Extra data" and empty stderr, which read as a broken tool
  # and silently dropped every IaC security finding. Decode the stream instead.
  if python3 - "$RAW/.checkov.parts" "$RAW/checkov.json" <<'PY'
import json, sys
try:
    buf = open(sys.argv[1]).read()
except OSError:
    buf = ""
dec, idx, failed = json.JSONDecoder(), 0, []
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    try:
        doc, idx = dec.raw_decode(buf, idx)
    except ValueError:
        break
    # checkov emits a bare list when several frameworks report; each element has its own `results`.
    for d in (doc if isinstance(doc, list) else [doc]):
        if isinstance(d, dict):
            failed.extend((d.get("results") or {}).get("failed_checks") or [])
if not buf.strip():
    raise SystemExit("checkov produced no output")
json.dump({"results": {"failed_checks": failed}}, open(sys.argv[2], "w"))
PY
  then
    note checkov "ok"
  else
    skip "checkov" "unparseable output: $(excerpt "$RAW/.checkov.err")"
    rm -f "$RAW/checkov.json"
  fi
  rm -f "$RAW/.checkov.parts"
fi

if need tfsec; then
  # tfsec takes a single directory. Run per directory and merge; `results` may be null when clean.
  : > "$RAW/.tfsec.parts"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    tfsec --format json --no-colour --soft-fail "$d" >> "$RAW/.tfsec.parts" 2>/dev/null
  done < "$DIRS"
  if python3 - "$RAW/.tfsec.parts" "$RAW/tfsec.json" <<'PY'
import json, sys
buf = open(sys.argv[1]).read()
dec, idx, results = json.JSONDecoder(), 0, []
while idx < len(buf):
    while idx < len(buf) and buf[idx] in " \t\r\n":
        idx += 1
    if idx >= len(buf):
        break
    try:
        doc, idx = dec.raw_decode(buf, idx)
    except ValueError:
        break
    results.extend(doc.get("results") or [])
json.dump({"results": results}, open(sys.argv[2], "w"))
PY
  then
    note tfsec "ok"
  else
    skip "tfsec" "could not merge per-directory output"
  fi
  rm -f "$RAW/.tfsec.parts"
fi

rm -f "$RAW/.checkov.err" "$RAW/.fmt-out" "$TF" "$DIRS" 2>/dev/null
exit 0
