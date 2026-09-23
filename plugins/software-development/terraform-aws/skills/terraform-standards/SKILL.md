---
name: terraform-standards
license: MIT
description: "Module layout, variable and output conventions, S3 state backend configuration with locking, workspaces versus a directory per environment, provider version pinning, and fmt/validate/plan discipline for Terraform on AWS. Use when scaffolding a new Terraform project, adding a backend, deciding how environments are separated, or working out why a plan is doing something unexpected."
---

# Terraform Standards

## Module layout

A Terraform repository has two kinds of directory, and conflating them is the most common
structural mistake.

| Kind | Contains | Has a backend? | Named |
| --- | --- | --- | --- |
| **Root module** | The composition for one environment of one component. Calls child modules, supplies environment values. | Yes — exactly one state file. | `infrastructure/terraform/`, or `environments/<env>/` |
| **Child module** | Reusable resource logic with no environment knowledge. | No. Never. | `modules/<name>/` |

A child module that reads an environment name and switches behaviour on it is a root
module wearing the wrong hat. Pass the behaviour in as a variable instead; the caller knows
which environment it is, the module does not need to.

Inside a root module, split by file so a reader can find things without grep:

```
infrastructure/terraform/
├── versions.tf      # terraform { required_version, required_providers }
├── providers.tf     # provider blocks, default_tags
├── variables.tf     # every input, typed and described
├── locals.tf        # derived names and tag maps
├── main.tf          # the resources and module calls
├── outputs.tf       # what other stacks consume
└── backends/
    ├── dev.s3.tfbackend
    ├── staging.s3.tfbackend
    └── prod.s3.tfbackend
```

One state file per component per environment. The temptation to put the whole estate in one
root module is strong early and fatal later: every plan touches everything, every apply
holds one lock, and a typo in an unrelated resource blocks the change you actually need.

## Variables

- **Type every variable.** `type = string` at minimum; `object({...})` for structured
  input. `any` is an admission that nobody knows the shape yet, and it defers the error
  from plan time to apply time.
- **Describe every variable.** The description is what a reader sees in `terraform
  console`, in generated docs, and in the error when validation fails.
- **No default on anything that distinguishes environments.** `environment`,
  `account_id`, `vpc_id` and sizing knobs must be supplied. A default on `environment`
  means a forgotten `-var-file` silently plans against the wrong one — and it plans
  cleanly, which is the problem.
- **Defaults are fine on things that are genuinely optional** — a retention period, an
  `enable_x` flag that is off, a tag map that starts empty.
- **Use `validation` blocks for the constraints you would otherwise write in a comment.**

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment. Drives naming, sizing and tagging."

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "environment must be one of: dev, staging, production."
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefix for every resource name in this stack, e.g. <org>-billing-api."
}
```

Mark secrets `sensitive = true`, and do not pass real secret values through `tfvars` at
all — read them from the parameter store or secrets manager with a data source. See
`dev-standards` → `secrets-management` for the path conventions.

## Outputs

An output is an API. Everything you export, something else can come to depend on, and you
will not find out which until you try to remove it.

- Export only what another stack or a human genuinely consumes. Not "everything, just in
  case."
- `description` on every output, same reason as variables.
- `sensitive = true` on anything that would otherwise print in CI logs. Note what this
  does and does not do: it redacts the CLI output. **The value is still in state in
  plaintext.** State is a secret-bearing artifact regardless.
- Prefer publishing cross-stack values to a parameter store over having the consuming
  stack read your remote state. A remote state read couples the consumer to your internal
  resource names and grants it read access to every other value in your state file. A
  parameter is one value with its own access control.

## State backend

### The shape

State lives in S3, encrypted with a customer-managed KMS key, with locking enabled, and
the bucket is versioned. Every value below is a placeholder:

```hcl
# backends/dev.s3.tfbackend — supplied at init, not committed into the backend block
region       = "us-east-1"
bucket       = "<org>-tfstate-dev"
key          = "<org>/aws/<team>/dev/<project-name>/backend.tfstate"
encrypt      = true
use_lockfile = true
kms_key_id   = "alias/<org>-terraform-state"

assume_role = {
  role_arn = "arn:aws:iam::111111111111:role/<terraform-state-role>"
}
```

with the backend block itself left partial in `versions.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

and initialised per environment:

```
terraform init -reconfigure -backend-config=backends/dev.s3.tfbackend
```

### Why partial, and why it matters

`terraform init` with no `-backend-config` against a partial backend block does not fail.
It falls back to **local state**, writes `terraform.tfstate` next to your `.tf` files, and
proceeds to plan a complete greenfield estate because as far as it knows nothing exists
yet. The resulting plan is a long list of creates for resources that are already running.

That failure is quiet, and it is quiet in the direction of doing damage, so it deserves a
mechanism rather than a note in a README: a pre-commit or pre-apply hook that refuses to
run when a local `terraform.tfstate` exists in a directory whose backend block is partial.
Two lines of shell, and it removes the whole class.

### The key path is the only thing that varies per project

Bucket, KMS alias, region and role are properties of the *environment*. The `key` is the
property of the *project*. When scaffolding a new project, copy the three backend files
from an existing one and change only the `key`. Do not derive a bucket name from a pattern
you think you remember — read it from a project that is known to work, or from the
platform team's documented value.

Two conventions that pay for themselves, both learned the hard way:

- **Use the full word in the key path.** If your environments are `dev` / `staging` /
  `production`, do not let the key say `prod` in one project and `production` in another.
  A key path mismatch creates a second, empty state file rather than an error.
- **If the backend *file* is named `prod.s3.tfbackend` but the key inside says
  `production`, write that down where someone scaffolding will see it.** Any place two
  spellings of one environment coexist is a place a future reader will "fix" one of them.

### Locking

Concurrent applies against one state file corrupt it. Terraform's S3 backend supports
native locking via `use_lockfile = true`, which writes a lock object beside the state
object; older setups use a DynamoDB table via `dynamodb_table`. Use one. Verify which your
Terraform version supports before choosing — the native option is the newer of the two and
the DynamoDB path is on its way out, so a mixed estate is worth normalising deliberately
rather than per project.

A lock that is never contended looks identical to no lock at all. The time you find out is
the time two pipeline runs overlap, so treat "locking is configured" as something to check
in review, not something to assume.

### State is sensitive

Every value your configuration touches — generated passwords, secret data source results,
private IPs, full resource inventories — is in the state file in plaintext. Therefore:
bucket is private and versioned, encryption uses a customer-managed key, and read access
to the state bucket is granted with the same seriousness as read access to the secrets
manager. Bucket versioning is not optional; it is the only undo you have for a corrupt or
truncated state write.

## Workspaces versus a directory per environment

Use **separate backend configurations** — one per environment, as above. Do not use
`terraform workspace` to separate dev from production.

The argument is not stylistic. Workspaces share one backend, which means one bucket, one
KMS key and one assumed role for every environment in the set. The consequences:

- The production state and the dev state are protected by the same access control. Anyone
  who can plan dev can read production state.
- The current workspace is **session state in your shell**, not a property of the command
  you typed. `terraform apply` is the same keystrokes whether you are pointed at dev or
  production, and the only thing standing between them is a `select` you ran earlier.
- You cannot give the pipeline a production-only identity, because the same backend
  configuration must work for all of them. That takes the single best control off the
  table.

Directory-per-environment costs you some duplication in `backends/` and gains you the
ability to say: this credential can reach dev, and it physically cannot reach production.

Workspaces are genuinely useful for **ephemeral copies of the same environment** — a
short-lived stack per feature branch, per test run, per reviewer — where every copy has the
same blast radius and the same credential. That is the case they were designed for.

## Provider and version pinning

```hcl
terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}
```

- **Pin `required_version`.** A newer Terraform CLI can write a state file an older one
  refuses to read; the first person to run the new version upgrades state for everyone.
- **Constrain every provider**, including the ones you only use for a data source. An
  unconstrained provider resolves to whatever was newest the day someone ran `init`, which
  makes two engineers' plans differ for reasons neither can see.
- **Commit `.terraform.lock.hcl`.** The constraint expresses intent; the lock file
  expresses what is actually running. Without it, `~> 5.70` is a range, not a version.
  Update it deliberately with `terraform init -upgrade`, in its own change, and read the
  provider changelog for the resources you use.
- Note that the review pipeline's `deps` detector reads package manifests — npm, pip,
  Dockerfiles, workflow files — and **not** `.tf` provider constraints. Provider pinning is
  caught by a `tflint` ruleset if you have configured one, and otherwise by a human. Do not
  assume the scan has it covered.

## fmt, validate, plan

Four commands, in this order, and each answers a different question:

```
terraform fmt -recursive
terraform init -backend-config=backends/dev.s3.tfbackend
terraform validate
terraform plan -out=tfplan
```

| Command | Answers | Needs credentials? |
| --- | --- | --- |
| `fmt -check` | Is it canonically formatted? | No |
| `validate` | Is it internally consistent — types, references, required arguments? | No, but it needs `init` to have downloaded providers |
| `plan` | What would change in *this* state, right now? | Yes |

`fmt` and `validate` belong in pre-commit, where they cost nothing and fail in under a
second. `plan` does not belong in pre-commit: it needs credentials and a backend, and a
hook that authenticates is a hook people disable.

Read the plan. All of it, including the `# forces replacement` comments and the summary
line. A plan you skimmed is not a review, and `terraform-review` in this plugin is
entirely about what to look for in one.

## Designing out the laptop apply

The single highest-value structural decision in a Terraform estate: **make it impossible,
not inadvisable, to apply to a shared environment from a personal machine.**

Why it has to be impossible rather than discouraged:

- **The working tree is unreviewed.** A local apply ships whatever is on disk — including
  the debugging change you meant to delete — and nothing in the state file records that the
  applied configuration never existed in a commit.
- **There is no artifact.** Nobody else saw the plan. When the resource changes shape two
  weeks later, the archaeology starts at "who was working that day".
- **The identity is a person.** Audit logs attribute the change to a human session with
  broad permissions rather than to a pipeline run with narrow ones, and that person's
  laptop is now in the blast radius of the production estate.
- **Drift is invisible until the next plan.** Local apply and pipeline apply race; the next
  pipeline run proposes to undo the local change, and whoever reads that plan has no
  context for why.

The mechanism, expressed in IAM rather than in prose:

1. The shared-environment backends assume a **state role** that trusts only the pipeline's
   identity. A personal SSO session that tries to assume it gets `AccessDenied` on
   `sts:AssumeRole` — before any plan runs, so there is no partial state write to clean up.
2. Local identities are scoped to the sandbox environment only, where the cost of a bad
   apply is a rebuild.
3. Shared environments are reached through a **manual gate in the pipeline**. The plan is
   the artifact; the gate is the approval; the job log is the audit trail.
4. Read-only inspection of shared environments stays available. Being unable to change
   production is not the same as being unable to look at it, and taking away the second
   only teaches people to reach for a bigger role.

The tell that you have got this right: when someone new runs `terraform plan` against
production by mistake, it fails on credentials in three seconds, and the failure teaches
them the rule.
