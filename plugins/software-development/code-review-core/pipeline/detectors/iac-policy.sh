#!/usr/bin/env bash
# iac-policy.sh — the team's Terraform and migration conventions that no installed linter checks.
#
# WHY A DETECTOR OF OUR OWN. tflint, checkov and tfsec cover the generic rules. The rules here are
# the ones terraform-aws and dev-standards write down as review findings, which are text-decidable
# and cheap enough to check on every change:
#
#   tf-target-in-pipeline          `-target` on a plan/apply/destroy in CI or a Makefile
#   tf-backend-dynamodb-lock       an S3 backend locking through the deprecated `dynamodb_table`
#   tf-env-variable-default        a default on a variable that distinguishes environments
#   tf-variable-undocumented       a variable with no description (tflint's
#                                  terraform_documented_variables, which is off by default)
#   iam-oidc-trust-without-sub     AssumeRoleWithWebIdentity with no `:sub` condition anywhere in it
#   iam-stringlike-without-wildcard a StringLike condition whose values hold no `*` or `?`
#   iam-passrole-wildcard          iam:PassRole in a statement whose resource is "*"
#   sql-index-not-concurrent       CREATE INDEX without CONCURRENTLY in a PostgreSQL migration
#
# WHY IT IS NOT A SECTION OF terraform.sh. terraform.sh is a wrapper around four binaries and skips
# each one that is absent. These rules need only python3, so they run on machines where every one of
# those binaries is missing, which is the common case on a laptop. They also read files terraform.sh
# never selects (CI pipelines, Makefiles, .sql migrations). One detector, one skip record.
#
# THE RULES UNDER-REPORT BY DESIGN. Each one reads text, not a parsed plan: a condition key built
# entirely from a variable, or a resource list passed in from a module, is invisible to it. When a
# rule cannot tell, it stays silent instead of guessing, because a noisy rule is one a reader learns
# to skip. No rule emits BLOCKER: a text match is a shortlist for the reviewer to confirm.
#
# Detector contract: see _lib.sh. Always exits 0.

set -uo pipefail

LIST="${1:?changed-files list required}"
OUT="${2:?outdir required}"
RAW="$OUT/raw"
# shellcheck source=./_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_lib.sh"

mkdir -p "$RAW"

SRC="$RAW/.iac-policy-files"
: > "$SRC"
# The selection is a path shape, not an extension, for the pipeline files: a workflow is a .yml like
# any other YAML, and a Makefile has no extension. The arms must stay identical to SIG_POLICY in
# review-scan.sh, or the scan dispatches a detector that then skips (or never dispatches one that
# would have found something).
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  case "$f" in
    *.tf|*.hcl|*.tfbackend) printf '%s\n' "$f" >> "$SRC" ;;
    .github/workflows/*.yml|.github/workflows/*.yaml|*/.github/workflows/*.yml|*/.github/workflows/*.yaml) printf '%s\n' "$f" >> "$SRC" ;;
    .gitlab-ci.yml|*/.gitlab-ci.yml|*.gitlab-ci.yml|.circleci/*.yml|azure-pipelines.yml|bitbucket-pipelines.yml|.buildkite/*.yml) printf '%s\n' "$f" >> "$SRC" ;;
    Jenkinsfile|*/Jenkinsfile|Jenkinsfile.*|*/Jenkinsfile.*|Makefile|*/Makefile|*.mk) printf '%s\n' "$f" >> "$SRC" ;;
    *.sql) printf '%s\n' "$f" >> "$SRC" ;;
  esac
done < "$LIST"

if ! any_lines "$SRC"; then
  skip "iac-policy" "no Terraform, CI pipeline, Makefile or .sql file in the diff"
  rm -f "$SRC"
  exit 0
fi

need python3 || { rm -f "$SRC"; exit 0; }

if ! python3 - "$SRC" "$RAW/iac-policy.json" <<'PY'
"""Text-decidable Terraform, IAM and migration rules. Output shape matches deps.sh and
comments.sh; normalize.py's `p_iac_policy` reads it."""
import json
import os
import re
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
findings = []


def add(path, line, rule, severity, category, title, rec):
    findings.append({"path": path, "line": line, "rule": rule, "severity": severity,
                     "category": category, "title": title, "recommendation": rec})


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def brace_pairs(text):
    """Every matched {...} as (open, close) offsets.

    Quoted strings and line comments are skipped, so a `{` inside "${var.x}" or a comment does not
    unbalance the count. Heredoc bodies are NOT quoted, so the braces of a JSON policy inside
    `<<EOF` are counted, which is what the IAM rules need.
    """
    pairs, stack, i, n = [], [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"' and text[i] != "\n":
                i += 2 if text[i] == "\\" else 1
        elif c == "#" or (c == "/" and text[i:i + 2] == "//"):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif c == "{":
            stack.append(i)
        elif c == "}" and stack:
            pairs.append((stack.pop(), i))
        i += 1
    return pairs


def innermost(pairs, pos):
    inside = [p for p in pairs if p[0] < pos < p[1]]
    return max(inside, key=lambda p: p[0]) if inside else None


def outermost(pairs, pos):
    inside = [p for p in pairs if p[0] < pos < p[1]]
    return min(inside, key=lambda p: p[0]) if inside else None


def block_after(pairs, pos):
    """The block whose `{` is the first one at or after pos."""
    after = [p for p in pairs if p[0] >= pos]
    return min(after, key=lambda p: p[0]) if after else None


# ------------------------------------------------------------------ Terraform (.tf / .hcl)
ENV_VARS = {"environment", "env", "stage", "environment_name", "account_id", "aws_account_id",
            "vpc_id"}


def scan_terraform(path, text):
    pairs = brace_pairs(text)

    for m in re.finditer(r'(?m)^[ \t]*variable\s+"([^"]+)"\s*\{', text):
        blk = block_after(pairs, m.end() - 1)
        if not blk:
            continue
        body = text[blk[0] + 1:blk[1]]
        name = m.group(1)
        if not re.search(r"(?m)^[ \t]*description\s*=", body):
            add(path, line_of(text, m.start()), "tf-variable-undocumented", "NIT", "ARCHITECTURE",
                f'Variable "{name}" has no description.',
                "Add a description. This is tflint's terraform_documented_variables, which is off "
                "by default; enable it in the repo's .tflint.hcl so CI enforces it.")
        d = re.search(r"(?m)^[ \t]*default\s*=", body)
        if name.lower() in ENV_VARS and d:
            add(path, line_of(text, blk[0] + 1 + d.start()), "tf-env-variable-default", "MAJOR",
                "RELIABILITY",
                f'Variable "{name}" distinguishes environments but has a default.',
                "Remove the default. With one, a run that forgets its -var-file plans cleanly "
                "against the default environment instead of failing.")

    backends = [(m.start(), block_after(pairs, m.end() - 1))
                for m in re.finditer(r'backend\s+"s3"\s*\{', text)]
    # A partial backend config file (backend.hcl, *.tfbackend) holds the arguments at top level.
    if path.endswith((".hcl", ".tfbackend")) and not backends and "dynamodb_table" in text:
        backends = [(0, (-1, len(text)))]
    for start, blk in backends:
        if not blk:
            continue
        body = text[blk[0] + 1:blk[1]]
        dyn = re.search(r"(?m)^[ \t]*dynamodb_table\s*=", body)
        if dyn and not re.search(r"(?m)^[ \t]*use_lockfile\s*=\s*true", body):
            add(path, line_of(text, blk[0] + 1 + dyn.start()), "tf-backend-dynamodb-lock", "MINOR",
                "RELIABILITY",
                "S3 backend locks through the deprecated dynamodb_table argument.",
                "Set use_lockfile = true (S3-native locking). Keep dynamodb_table only while "
                "migrating: apply once from every pipeline with both set, then remove it.")

    scan_iam(path, text, pairs)


# ------------------------------------------------------------------ IAM (inside .tf)
def scan_iam(path, text, pairs):
    for m in re.finditer(r"sts:AssumeRoleWithWebIdentity", text):
        blk = outermost(pairs, m.start())
        body = text[blk[0]:blk[1]] if blk else text
        if not re.search(r":sub\b", body):
            add(path, line_of(text, m.start()), "iam-oidc-trust-without-sub", "MAJOR", "SECURITY",
                "OIDC trust policy allows AssumeRoleWithWebIdentity with no condition on `sub`.",
                "Add a StringEquals (or narrowly wildcarded StringLike) condition on "
                "<issuer>:sub naming the exact repository, branch or environment. With only `aud`, "
                "any workflow the provider issues tokens for can assume this role. If the key is "
                "built from a variable, confirm it resolves to `:sub`.")

    for m in re.finditer(r'(?i)"?iam:PassRole"?', text):
        blk = innermost(pairs, m.start())
        if not blk:
            continue
        body = text[blk[0]:blk[1] + 1]
        if re.search(r'(?i)\bresources?"?\s*[=:]\s*\[?\s*"\*"', body):
            add(path, line_of(text, m.start()), "iam-passrole-wildcard", "MAJOR", "SECURITY",
                'iam:PassRole is granted on Resource "*".',
                "Scope PassRole to the specific role ARNs (or a path) the service needs, and add "
                "an iam:PassedToService condition. On \"*\" the principal can hand any role, "
                "including an unbounded one, to a service it can launch.")

    # StringLike in an aws_iam_policy_document condition block: test = "StringLike".
    for m in re.finditer(r'test\s*=\s*"StringLike"', text):
        blk = innermost(pairs, m.start())
        if not blk:
            continue
        vals = re.search(r"values\s*=\s*\[(.*?)\]", text[blk[0]:blk[1]], re.S)
        if vals:
            check_stringlike(path, text, m.start(), vals.group(1))

    # StringLike as a key in jsonencode() or a JSON heredoc: StringLike = { ... } / "StringLike": {
    for m in re.finditer(r'"?StringLike"?\s*[=:]\s*\{', text):
        blk = block_after(pairs, m.end() - 1)
        if blk:
            check_stringlike(path, text, m.start(), text[blk[0] + 1:blk[1]])


def check_stringlike(path, text, pos, body):
    # Value strings only: a quoted string followed by `=` or `:` is a condition KEY.
    values = [s.group(1) for s in re.finditer(r'"([^"]*)"(?!\s*[=:])', body)]
    # A bare reference (var.x, local.y) among the values could hold a wildcard; stay silent.
    if not values or re.search(r"(?<![\"\w])(var|local|module|data)\.", body):
        return
    if not any("*" in v or "?" in v for v in values):
        add(path, line_of(text, pos), "iam-stringlike-without-wildcard", "MINOR", "SECURITY",
            "StringLike condition has no wildcard in any value.",
            "Use StringEquals for exact values. A StringLike with no `*` or `?` invites the next "
            "editor to widen it with a wildcard that nobody reviews as a trust change.")


# ------------------------------------------------------------------ CI pipelines and Makefiles
TF_CMD = re.compile(r"\b(terraform|tofu|terragrunt)\b|\$\(TF\)|\$\{TF\}|\$TF\b")
TF_VERB = re.compile(r"\b(plan|apply|destroy)\b")
TARGET = re.compile(r"(?<![\w-])-target[=\s]")


def scan_pipeline(path, text):
    # Join backslash continuations so a flag on the next line still belongs to its command.
    logical, start = "", 1
    for i, raw in enumerate(text.splitlines() + [""], 1):
        if not logical:
            start = i
        stripped = raw.strip()
        if stripped.startswith(("#", "//")):
            continue
        if stripped.endswith("\\"):
            logical += stripped[:-1] + " "
            continue
        logical += stripped
        if TARGET.search(logical) and TF_CMD.search(logical) and TF_VERB.search(logical):
            add(path, start, "tf-target-in-pipeline", "MAJOR", "RELIABILITY",
                "Terraform plan/apply/destroy runs with -target in an automated path.",
                "Remove -target. It applies part of the configuration, so state drifts from code "
                "and the next full plan shows surprises. Split the root module if parts need "
                "separate applies.")
        logical = ""


# ------------------------------------------------------------------ SQL migrations
def scan_sql(path, text):
    # Only migrations, and only PostgreSQL: CONCURRENTLY is PostgreSQL syntax, and an index in a
    # seed or schema dump is not a live-table change.
    if "migrat" not in path.lower():
        return
    if re.search(r"(?i)\bENGINE\s*=|`", text):
        return  # MySQL dialect; the non-blocking form there is ALGORITHM=INPLACE, LOCK=NONE
    code = re.sub(r"--[^\n]*", "", text)
    code = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), code, flags=re.S)
    created = {t.lower().split(".")[-1].strip('"') for t in re.findall(
        r"(?i)\bCREATE\s+(?:UNLOGGED\s+|TEMP(?:ORARY)?\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.\"]+)",
        code)}
    for m in re.finditer(
            r"(?i)\bCREATE\s+(?:UNIQUE\s+)?INDEX\s+(?!CONCURRENTLY\b)[^;]*?\bON\s+(?:ONLY\s+)?([\w.\"]+)",
            code):
        table = m.group(1).lower().split(".")[-1].strip('"')
        if table in created:
            continue  # a table created in this migration is empty; its index locks nothing
        add(path, line_of(code, m.start()), "sql-index-not-concurrent", "MAJOR", "RELIABILITY",
            f"CREATE INDEX on existing table {m.group(1)} without CONCURRENTLY.",
            "Use CREATE INDEX CONCURRENTLY, which does not block writes. It cannot run inside a "
            "transaction, so disable the migration tool's wrapping transaction for this file.")


for path in [l.strip() for l in open(src_path).read().splitlines() if l.strip()]:
    try:
        with open(path, errors="replace") as fh:
            text = fh.read()
    except OSError:
        continue
    if path.endswith((".tf", ".hcl", ".tfbackend")):
        scan_terraform(path, text)
    elif path.endswith(".sql"):
        scan_sql(path, text)
    else:
        scan_pipeline(path, text)

json.dump({"findings": findings}, open(out_path, "w"))
print(f"{len(findings)} iac-policy finding(s)", file=sys.stderr)
PY
then
  skip "iac-policy" "policy scan failed"
  rm -f "$RAW/iac-policy.json"
else
  note iac-policy "ok"
fi

rm -f "$SRC" 2>/dev/null
exit 0
