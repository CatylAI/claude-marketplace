---
name: secrets-management
description: "Use when adding a credential, naming a secret or config store path, wiring config into a deployment, or reviewing code that reads a secret. Path conventions and how code and Terraform reference them. Not for scanning for leaked keys (use dev-guardrails:security-scan)."
license: MIT
---

# Secrets and Config Standards

Secrets and non-sensitive config have different lifecycles, so they get different path shapes:
a glance at a path tells you which one you are holding.

## Path formats

| Kind | Shape | Example |
| --- | --- | --- |
| Secret (sensitive) | `/{namespace}/secrets/{type}/{key}` | `/platform/secrets/db/aurora-password` |
| Config or stack output (non-sensitive) | `/{namespace}/{project}/{environment}/{key}` | `/platform/billing-api/prod/api-endpoint` |

| Segment | Meaning | Examples |
| --- | --- | --- |
| `namespace` | Owning org or team | `platform`, `shared` |
| `type` | Credential category, closed set | `api`, `db`, `oauth`, `cert` |
| `project` | Service name | `billing-api`, `chat-gateway` |
| `environment` | Deploy environment | `dev`, `staging`, `prod` |
| `key` | Kebab-case identifier | `billing-service-key`, `lambda-arn` |

The environment appears in the config path and not in the secret path, because secrets are
already separated by account or vault per environment. Encoding it twice means one copy
eventually drifts.

## Terraform

Prefer handing the service the secret's **path** and letting it read the value at runtime:

```hcl
resource "aws_lambda_function" "main" {
  # ...
  environment {
    variables = {
      API_KEY_PARAM = "/${var.namespace}/secrets/api/billing-service-key"
    }
  }
}

# Publish a non-sensitive output for other stacks to consume
resource "aws_ssm_parameter" "lambda_arn" {
  name  = "/${var.namespace}/${var.project_name}/${var.environment}/lambda-arn"
  type  = "String"
  value = aws_lambda_function.main.arn
}
```

When Terraform itself must read the value (a `data "aws_ssm_parameter"` with
`with_decryption = true`, for example), the decrypted value is stored in Terraform state. Keep
the state backend encrypted and readable only by the deploy role, and mark derived outputs
`sensitive = true`. Keep secret values out of `.tfvars` files and HCL literals.

## Rules

- Keep secret values out of source, config files, test fixtures, docs and commit messages;
  write the store path or a reference (`op://…`, an environment-variable name) instead.
- Commit `.env.example` with placeholders; keep the real `.env` untracked.
- Redact before logging: a secret in a log line, error message or CI log is a leak.
- Give each environment its own credential, so rotating one never breaks another.
- Populate local environments from the secrets manager CLI, into a variable or file rather
  than onto the screen. If `dev-guardrails` is installed, its Bash hook blocks commands that
  print a secret into the transcript and says which form to use instead.
- Rotate on exposure. A secret that appeared in a log, a screenshot or a pushed commit is
  burned even if the commit was reverted, because a revert does not un-publish history.

## Reviewing

For each secret the change touches, check: the path matches the shape above; the value never
appears in the diff; the reading code fetches by path; and, if Terraform reads it, the state
backend is restricted. Report a literal value as a leaked credential (rotate, then purge) and a
wrong path shape as a convention finding.
