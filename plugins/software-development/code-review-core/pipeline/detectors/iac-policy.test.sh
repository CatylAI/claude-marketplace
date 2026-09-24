#!/usr/bin/env bash
# iac-policy.test.sh — the policy detector's own arms, below the generic contract.
#
#   bash pipeline/detectors/iac-policy.test.sh
#   zsh  pipeline/detectors/iac-policy.test.sh
#
# `detectors.test.sh` asserts the CONTRACT every detector shares. This file asserts, for each rule:
#
#   1. It fires on the planted defect, at the right line and tier.
#   2. It stays SILENT on the compliant shape next to it. Half of the fixtures below are the
#      corrected form of a positive one (StringEquals instead of a wildcard-free StringLike, a
#      scoped PassRole, an index on a table the same migration creates), because a policy rule that
#      fires on correct code is worse than no rule: it teaches the reader to skip the rule id.
#
# Every fixture is built under $TMP and removed by the trap. No repository is touched, no network.
#
# Portable bash 3.2+ / zsh.

set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DET="$SELF_DIR/iac-policy.sh"
NORMALIZE="$SELF_DIR/../normalize.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/iac-policy-test.XXXXXX")"

PASS=0 FAIL=0 SKIP=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
skipt() { SKIP=$((SKIP + 1)); printf '  skip %s (%s)\n' "$1" "$2"; }
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

printf 'iac-policy detector tests (shell: %s)\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash $BASH_VERSION}"

if ! command -v python3 >/dev/null 2>&1; then
  skipt "every case" "python3 not on PATH"
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  exit 0
fi

t="detectors/iac-policy.sh is executable"
if [ -x "$DET" ]; then pass "$t"; else fail "$t" "the executable bit is not set"; fi

WT="$TMP/wt"
mkdir -p "$WT/infra" "$WT/.github/workflows" "$WT/db/migrations" "$WT/db/seeds"

# ------------------------------------------------------------------ positive fixtures
cat > "$WT/infra/bad.tf" <<'EOF'
variable "environment" {
  type        = string
  description = "Deployment environment."
  default     = "dev"
}

variable "bucket_name" {
  type = string
}

terraform {
  backend "s3" {
    bucket         = "state"
    key            = "app.tfstate"
    dynamodb_table = "locks"
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gh.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["iam:PassRole"]
    resources = ["*"]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::b/*"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["reports"]
    }
  }
}

resource "aws_iam_policy" "json" {
  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Action    = "s3:ListBucket"
      Resource  = "arn:aws:s3:::b"
      Condition = { StringLike = { "s3:prefix" = "home" } }
    }]
  })
}
EOF

cat > "$WT/.github/workflows/deploy.yml" <<'EOF'
jobs:
  deploy:
    steps:
      - run: |
          terraform apply -auto-approve \
            -target=module.app
EOF

cat > "$WT/Makefile" <<'EOF'
apply:
	$(TF) apply -target=aws_s3_bucket.b
EOF

cat > "$WT/db/migrations/002_index.sql" <<'EOF'
-- add a lookup index
CREATE INDEX idx_orders_user ON orders (user_id);
EOF

# ------------------------------------------------------------------ negative fixtures
cat > "$WT/infra/good.tf" <<'EOF'
variable "environment" {
  type        = string
  description = "Deployment environment."
}

variable "retention_days" {
  type        = number
  description = "Log retention."
  default     = 30
}

terraform {
  backend "s3" {
    bucket       = "state"
    key          = "app.tfstate"
    use_lockfile = true
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gh.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:acme/app:environment:prod"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:acme/app:ref:refs/heads/release/*"]
    }
  }
}

data "aws_iam_policy_document" "ci" {
  statement {
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::111111111111:role/app/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = var.prefixes
    }
  }
}
EOF

cat > "$WT/.github/workflows/plan.yml" <<'EOF'
jobs:
  plan:
    steps:
      # never use terraform apply -target here
      - run: terraform plan -out=tfplan
      - run: clang -target x86_64-linux-gnu main.c
EOF

cat > "$WT/db/migrations/001_create.sql" <<'EOF'
CREATE TABLE orders (id bigint primary key, user_id bigint);
CREATE INDEX idx_orders_user ON orders (user_id);
CREATE INDEX CONCURRENTLY idx_users_email ON users (email);
EOF

cat > "$WT/db/seeds/indexes.sql" <<'EOF'
CREATE INDEX idx_seed ON users (name);
EOF

( cd "$WT" && printf '%s\n' infra/bad.tf infra/good.tf .github/workflows/deploy.yml \
    .github/workflows/plan.yml Makefile db/migrations/001_create.sql db/migrations/002_index.sql \
    db/seeds/indexes.sql > .changed )

OD="$TMP/out"
( cd "$WT" && bash "$DET" "$WT/.changed" "$OD" ) >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?

t="exits 0 and writes raw/iac-policy.json"
if [ "$rc" -eq 0 ] && [ -f "$OD/raw/iac-policy.json" ]; then pass "$t"
else fail "$t" "rc=$rc; stderr: $(head -c 400 "$TMP/stderr")"; fi

# hits <path> <rule> -> "line:severity" per finding, one per line
hits() {
  python3 - "$OD/raw/iac-policy.json" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for f in doc["findings"]:
    if f["path"] == sys.argv[2] and f["rule"] == sys.argv[3]:
        print(f'{f["line"]}:{f["severity"]}')
PY
}

expect() { # <label> <path> <rule> <expected "line:sev" list, space-separated, or empty>
  got="$(hits "$2" "$3" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" = "$4" ]; then pass "$1"; else fail "$1" "expected [$4], got [$got]"; fi
}

expect "default on environment fires at the default line"      infra/bad.tf  tf-env-variable-default      "4:MAJOR"
expect "default on an optional input is silent"                 infra/good.tf tf-env-variable-default      ""
expect "variable without description fires"                     infra/bad.tf  tf-variable-undocumented     "7:NIT"
expect "described variables are silent"                         infra/good.tf tf-variable-undocumented     ""
expect "dynamodb_table without use_lockfile fires"              infra/bad.tf  tf-backend-dynamodb-lock     "15:MINOR"
expect "use_lockfile backend is silent"                          infra/good.tf tf-backend-dynamodb-lock     ""
expect "OIDC trust with only aud fires"                          infra/bad.tf  iam-oidc-trust-without-sub   "21:MAJOR"
expect "OIDC trust with a sub condition is silent"               infra/good.tf iam-oidc-trust-without-sub   ""
expect "PassRole on * fires"                                     infra/bad.tf  iam-passrole-wildcard        "36:MAJOR"
expect "scoped PassRole beside a * statement is silent"          infra/good.tf iam-passrole-wildcard        ""
expect "StringLike without wildcard fires (HCL and jsonencode)"  infra/bad.tf  iam-stringlike-without-wildcard "43:MINOR 56:MINOR"
expect "StringLike with a wildcard, or from a variable, is silent" infra/good.tf iam-stringlike-without-wildcard ""
expect "-target across a continuation fires in a workflow"       .github/workflows/deploy.yml tf-target-in-pipeline "5:MAJOR"
expect "-target via \$(TF) fires in a Makefile"                  Makefile      tf-target-in-pipeline        "2:MAJOR"
expect "commented -target and clang -target are silent"          .github/workflows/plan.yml tf-target-in-pipeline ""
expect "CREATE INDEX on an existing table fires"                 db/migrations/002_index.sql sql-index-not-concurrent "2:MAJOR"
expect "index on a table created in the same migration is silent" db/migrations/001_create.sql sql-index-not-concurrent ""
expect "a .sql file outside migrations is silent"                db/seeds/indexes.sql sql-index-not-concurrent ""

t="normalize.py reads raw/iac-policy.json and keeps the detector's tiers"
python3 "$NORMALIZE" --raw "$OD/raw" --out "$TMP/norm.json" --repo-root "$WT" >/dev/null 2>"$TMP/norm.err"
if python3 - "$TMP/norm.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
fs = [f for f in doc.get("findings", []) if "iac-policy" in json.dumps(f)]
sevs = {f.get("severity") for f in fs}
assert fs, "no iac-policy findings after normalize"
assert "BLOCKER" not in sevs, sevs
assert {"MAJOR", "MINOR", "NIT"} <= sevs, sevs
PY
then pass "$t"; else fail "$t" "$(head -c 400 "$TMP/norm.err")"; fi

t="a diff with no policy files records a skip"
WT2="$TMP/none"; mkdir -p "$WT2"; printf 'x = 1\n' > "$WT2/app.py"; printf 'app.py\n' > "$WT2/.changed"
( cd "$WT2" && bash "$DET" "$WT2/.changed" "$TMP/out2" ) >/dev/null 2>&1
if grep -q 'no Terraform' "$TMP/out2/raw/iac-policy.skipped" 2>/dev/null && [ ! -f "$TMP/out2/raw/iac-policy.json" ]; then
  pass "$t"
else
  fail "$t" "skip record: $(cat "$TMP/out2/raw/iac-policy.skipped" 2>/dev/null || printf '<none>')"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
