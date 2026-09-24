# Version floors and example constraints

**Verify against current docs before use.** These values were checked on 2026-09-23 against
the Terraform and terraform-provider-aws changelogs and the GitHub OIDC reference. They rot;
re-check the sources (github.com/hashicorp/terraform, github.com/hashicorp/terraform-provider-aws,
docs.github.com) before copying a number or date into a configuration.

## Terraform CLI features and the version that introduced them

| Feature | Introduced | Notes |
| --- | --- | --- |
| `moved` blocks | 1.1 | |
| `import` blocks | 1.5 | `for_each` on `import` from 1.7 |
| `removed` blocks | 1.7 | `lifecycle { destroy = false }` to forget without destroying |
| Ephemeral resources, variables and outputs | 1.10 | not persisted to plan or state |
| S3 native locking (`use_lockfile`) | 1.10 | generally available in 1.11, which also deprecated `dynamodb_table` |
| Write-only arguments (for example `password_wo`) | 1.11 | not persisted to state |

At the check date the latest stable CLI was 1.16.x.

## Example constraints

```hcl
terraform {
  # Floor = the newest feature in use (here: native locking GA, write-only arguments).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # any 6.x; the lock file records the exact version
    }
  }
}
```

The AWS provider's 6.0 major release shipped on 2025-06-18; at the check date the provider was
at 6.66. A major-version bump is its own change: read the upgrade guide, run a plan in every
environment, and expect force-new attribute changes.

Pin the exact CLI in CI separately (for example `terraform_version: 1.16.4` in the setup
action, or a `.terraform-version` file); `required_version` is only a floor.
