---
name: terraform-aws
description: "Infrastructure standards for Terraform on AWS. Use when laying out a Terraform module or state backend, designing an IAM role or a CI trust policy, planning a schema migration that has to deploy without downtime, or reviewing an infrastructure change for blast radius. Covers the decisions a linter cannot make; it provisions nothing and runs no apply."
license: MIT
user-invocable: false
---

# Terraform on AWS

Four skills, one subject: infrastructure that a team can change safely on a Tuesday
afternoon. Everything here is written against **placeholders** — account ids, bucket
names, key aliases and role paths are `111111111111`, `<org>-tfstate-<env>`,
`alias/<org>-terraform-state` and `arn:aws:iam::111111111111:role/<role-name>`.
Substitute your own. Never paste an identifier out of an example into a backend file and
assume it is right; a wrong backend value does not error, it writes your state somewhere
else.

The through-line is a single idea: **the dangerous operations should be impossible from a
laptop, not merely discouraged.** A rule that says "do not apply to production locally" is
a wish. A state backend whose role is only assumable by the CI identity is a mechanism.
Every section below prefers the second kind.

## What is in here

| Component | Type | Use when |
|-----------|------|----------|
| `terraform-standards` | Skill | Laying out modules, writing variables and outputs, configuring a state backend and its locking, choosing between workspaces and a directory per environment, pinning providers, and running fmt / validate / plan in the right order. |
| `aws-iam-boundaries` | Skill | Designing a least-privilege role, wiring an assume-role chain, replacing long-lived CI access keys with OIDC federation, applying permission boundaries, and telling a harmless wildcard from a dangerous one. |
| `database-migrations` | Skill | A schema change has to ship without downtime: expand/contract, what makes a migration reversible, deploy ordering, and what to do when a migration cannot be rolled back. |
| `terraform-review` | Skill | Reviewing an infrastructure change — blast radius, destructive replacement, orphaned state. The judgement the scanners cannot supply. |

## Preconditions

These skills assume an AWS identity you can already use and a Terraform CLI on PATH. Check
both before you read a result as meaningful — an expired session and a correctly empty
plan are not the same thing, and they can look alike:

```
terraform version
aws sts get-caller-identity
```

If `get-caller-identity` returns an account you did not expect, stop. Everything downstream
is about to act on the wrong estate.

## Not this plugin's job

- **Provisioning anything.** No skill here creates a resource, runs `terraform apply`,
  attaches a policy or rotates a key. Where an action is implied, the skill says so and
  stops. The one place that distinction is load-bearing is `apply` itself: this plugin's
  position is that `apply` against shared state belongs to a pipeline with one identity and
  an audit trail, and a plugin that ran it for you would be arguing against its own advice.
- **The mechanical review checks.** `terraform fmt`, `tflint`, `checkov` and `tfsec` are
  run by the `terraform` detector in `code-review-core`. `terraform-review` does not
  restate what they catch — it covers what they cannot decide.
- **Secret storage.** Path conventions, prohibited practices and the "rotate on exposure"
  rule live in `dev-standards`' `secrets-management`. This plugin references secrets; it
  does not define how they are named or where they live.
- **Any other cloud, and any other IaC tool.** The migration discipline is portable. The
  rest is Terraform and AWS specifically.
- **Telling you your account is secure.** A skill can point at a wildcard. It cannot
  enumerate your effective permissions. Use IAM Access Analyzer and the policy simulator
  for that, and treat their output as evidence rather than these pages.
