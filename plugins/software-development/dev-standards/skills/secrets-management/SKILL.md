---
name: secrets-management
license: MIT
description: Naming conventions and access patterns for secrets and configuration in a parameter store or secrets manager, plus the practices that are always prohibited. Use when adding a credential, wiring config into a deployment, or reviewing code that reads or writes secret values.
---

# Secrets and Config Standards

Secrets and non-sensitive config are different things with different lifecycles. Give
them different path shapes so a glance at a path tells you which one you are holding.

## Two path formats

### 1. Secrets — sensitive values

```
/{namespace}/secrets/{type}/{key}
```

| Component | Meaning | Examples |
| --- | --- | --- |
| `namespace` | Owning org or team | `platform`, `shared` |
| `type` | Credential category | `api`, `db`, `oauth`, `cert` |
| `key` | Identifier | `service-api-key`, `postgres-password` |

```
/platform/secrets/api/billing-service-key
/platform/secrets/db/aurora-password
/platform/secrets/oauth/google-client-secret
/shared/secrets/api/metrics-provider-key
```

### 2. Config and outputs — non-sensitive values

```
/{namespace}/{project}/{environment}/{key}
```

| Component | Meaning | Examples |
| --- | --- | --- |
| `namespace` | Owning org or team | `platform` |
| `project` | Service name | `billing-api`, `chat-gateway` |
| `environment` | Deploy environment | `dev`, `staging`, `prod` |
| `key` | Resource identifier | `lambda-arn`, `bucket-name` |

```
/platform/billing-api/dev/loader-function-name
/platform/chat-gateway/prod/api-endpoint
```

The environment segment belongs in the config path and **not** in the secret path when
secrets are already separated by account or vault. Encoding the environment twice means
one of the two copies eventually drifts.

## Terraform patterns

```hcl
# Read a secret
data "aws_ssm_parameter" "api_secret" {
  name            = "/${var.namespace}/secrets/api/billing-service-key"
  with_decryption = true
}

# Publish a non-sensitive output for other stacks to consume
resource "aws_ssm_parameter" "lambda_arn" {
  name  = "/${var.namespace}/${var.project_name}/${var.environment}/lambda-arn"
  type  = "String"
  value = aws_lambda_function.main.arn
}
```

Never write a secret value into Terraform state as a plaintext literal, and never pass
one through a `tfvars` file committed to the repo. Reference the store; let the provider
resolve it at apply time.

## Prohibited, without exception

- No secrets in source code, config files, test fixtures, markdown, or commit messages.
- No committed `.env` file containing a real value. Commit `.env.example` with
  placeholders instead.
- No secrets in log output, error messages, or CI job logs — redact before printing.
- No sharing a single credential across environments. One secret per environment.

## Required

- Populate local environments from a secrets manager CLI, not from a file a teammate sent you.
- Use the platform secrets manager or parameter store for every deployed service.
- Reference secrets indirectly (`op://...` style references, environment variable names,
  or store paths) anywhere a value would otherwise be written down.
- Rotate on exposure. A secret that appeared in a log, a screenshot, or a pushed commit
  is burned even if the commit was reverted — revert does not un-publish.
