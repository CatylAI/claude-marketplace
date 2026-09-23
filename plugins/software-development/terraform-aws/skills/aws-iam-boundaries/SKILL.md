---
name: aws-iam-boundaries
license: MIT
description: "Least-privilege AWS role design, assume-role chains, OIDC federation from CI instead of long-lived access keys, permission boundaries, and how to read a policy for the wildcard that actually matters. Use when creating or reviewing an IAM role, trust policy or CI credential, or when deciding what a pipeline is allowed to reach."
---

# AWS IAM Boundaries

Every ARN, account id and role name on this page is a placeholder —
`111111111111`, `222222222222`, `<role-name>`, `<org>`. Substitute your own.

## Roles are for jobs, not for people

A role should answer one question: *what does this workload need in order to do its one
job?* Name it after the job, scope it to the job, and let people assume it rather than
holding a copy of its permissions.

| Anti-pattern | What it becomes | Instead |
| --- | --- | --- |
| A role per engineer | Permissions accrete and nothing is ever removed, because removing something might break "someone" | A small set of job roles, assumed by whoever is doing that job |
| One `deploy` role for every service | Any service's pipeline can act on any other service's resources | One deploy role per service, scoped by resource ARN prefix or tag |
| An IAM user with access keys for CI | A static credential in someone's secret store, valid until a human revokes it | Federated, short-lived credentials — see OIDC below |
| "Temporary" broad grant added during an incident | Permanent | A documented break-glass role with alerting on assumption |

Scope by resource, not only by action. `s3:GetObject` on `*` and `s3:GetObject` on
`arn:aws:s3:::<org>-app-dev-*/*` are different permissions that a policy-reading eye can
easily slide past.

## Assume-role chains

The pattern that removes standing permissions from compute:

```
CI compute identity                  target account role
(instance profile / OIDC principal)  (arn:aws:iam::111111111111:role/<deploy-role>)
        │                                     ▲
        │  policy: sts:AssumeRole only        │  trust policy: names the CI principal
        └─────────────────────────────────────┘  permission policy: what the job may do
```

Two properties make it worth the extra hop:

1. **The base identity can do nothing on its own.** Its only permission is
   `sts:AssumeRole` against an enumerated list of role ARNs. If that credential leaks, the
   attacker has the right to ask for roles they must also be trusted by.
2. **The trust relationship is the control, and it lives in the target account.** The team
   that owns the production account decides who may assume into it, and they can revoke it
   without coordinating with anyone.

The base identity's policy should list role ARNs explicitly:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AssumeDeployRolesOnly",
    "Effect": "Allow",
    "Action": "sts:AssumeRole",
    "Resource": [
      "arn:aws:iam::111111111111:role/<deploy-role>",
      "arn:aws:iam::222222222222:role/<deploy-role>"
    ]
  }]
}
```

`"Resource": "*"` on `sts:AssumeRole` is one of the wildcards that matters. It converts
"this runner may reach these two accounts" into "this runner may reach any role in the
organization that trusts a principal in its account", and the set of such roles is not
something you can enumerate from where you are standing.

### Failure modes worth naming

- **Skipping the hop and using the compute identity directly.** Works on day one, and
  quietly gives every job on that runner every permission any job on it ever needed.
- **A chain the CLI cannot follow.** If the job never configures the profile that performs
  the assumption, the SDK falls back to ambient credentials and fails with an
  authorization error that reads like a permissions problem. The first diagnostic is
  always `aws sts get-caller-identity` — print the identity the job is actually using
  before debugging what it is allowed to do.
- **Different role paths for different account classes.** Network or shared-services
  accounts often use a different role path from workload accounts. Write the mapping down
  once, in one table, and reference it; a half-remembered path produces `AccessDenied` that
  looks like a policy problem and is a typo.

## OIDC federation instead of long-lived keys

A CI system with an IAM user and an access key pair has a permanent credential stored
outside AWS. It does not expire, it is copied into every fork of the pipeline
configuration that someone tries locally, and rotating it is a coordinated change nobody
wants to schedule. Replace it with OIDC: the CI platform mints a short-lived, signed token
describing *which repository, which branch, which job*, and AWS exchanges it for
credentials that expire in an hour.

Register the provider once per account, then write a trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::111111111111:oidc-provider/<ci-issuer-host>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "<ci-issuer-host>:aud": "<expected-audience>"
      },
      "StringLike": {
        "<ci-issuer-host>:sub": "repo:<org>/<repo>:ref:refs/heads/main"
      }
    }
  }]
}
```

**The `sub` condition is the whole security boundary.** Get it wrong and the role is
assumable by CI jobs you do not own:

| `sub` condition | Who can assume | Verdict |
| --- | --- | --- |
| absent | Any job on that CI platform, any repository, anywhere | Broken. This is the misconfiguration that shows up in incident write-ups. |
| `repo:<org>/*:*` | Every repository in your organization, including forks a contributor can push to | Too broad for anything that can write |
| `repo:<org>/<repo>:*` | Every branch, tag and pull request of one repository | Acceptable for a read-only or plan-only role |
| `repo:<org>/<repo>:ref:refs/heads/main` | One branch of one repository | Right for a deploy role |
| `repo:<org>/<repo>:environment:production` | Jobs running in a protected environment, behind whatever approval it requires | Strongest, where the platform supports it |

Two more rules:

- **Always pin `aud` with `StringEquals`.** The audience is what stops a token minted for a
  different relying party from being replayed at yours.
- **`StringLike` only where a wildcard is intentional.** A `StringLike` with no `*` in the
  value should be a `StringEquals`; leaving it as `StringLike` invites someone to later add
  the wildcard "just for a moment".

Claim names and `sub` formats differ per CI platform and change over time. Read your
platform's current OIDC documentation and verify the actual claim values from a real token
in a test job before you rely on a condition — a condition that never matches fails
closed and is obvious, but a condition matching more than you intended is silent.

## Permission boundaries

A permission boundary is a **ceiling**, not a grant. Effective permissions are the
intersection of the identity policy and the boundary: the identity policy says what is
requested, the boundary says what is ever possible, and you need an `Allow` in both.

Two uses that justify the complexity:

1. **Delegating role creation safely.** You want application teams to create their own
   roles without being able to create one with `AdministratorAccess`. Grant them
   `iam:CreateRole` and `iam:PutRolePolicy`, conditioned on attaching a boundary you
   control:

   ```json
   {
     "Effect": "Allow",
     "Action": ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy"],
     "Resource": "arn:aws:iam::111111111111:role/<team-path>/*",
     "Condition": {
       "StringEquals": {
         "iam:PermissionsBoundary": "arn:aws:iam::111111111111:policy/<boundary-name>"
       }
     }
   }
   ```

   Without that condition the delegation is a privilege-escalation path: anyone who can
   create a role and attach a policy to it can create an admin and assume it.

2. **Capping a role whose permission policy is generated or broad.** A deploy role built
   from a module you did not write is easier to reason about with a boundary that forbids
   IAM writes, region use outside your footprint, and anything touching logging or billing.

Do not use a boundary as your only scoping. It sets a maximum; it does not make a
`Resource: "*"` policy acceptable, and a reviewer reading only the identity policy will
not see the ceiling.

## Reading a policy for the wildcard that matters

Not all wildcards are equal. Some are unavoidable — many `Describe`/`List` actions support
no resource-level permissions, so `Resource: "*"` is the only legal form. Triage in this
order:

| Pattern | Why it is serious |
| --- | --- |
| `"Action": "*"` with `"Resource": "*"` | Administrator, whatever the role is named |
| `"Action": "iam:*"`, or any `iam:Create*` / `iam:Put*` / `iam:Attach*` without a boundary condition | Self-escalation: the role can grant itself anything |
| `"Action": "iam:PassRole"` with `"Resource": "*"` | The role can hand *any* role to a service it can launch, and inherit those permissions indirectly. Always scope `PassRole` to the specific roles, and add an `iam:PassedToService` condition. |
| `"Action": "sts:AssumeRole"` with `"Resource": "*"` | Lateral movement across every trusting role |
| `"Action": "kms:*"` or `kms:Decrypt` on `"Resource": "*"` | Reads every encrypted artifact the account can see, state files included |
| `"Action": "s3:*"` on `"Resource": "*"` | Includes `DeleteObject` and bucket-policy writes, not just the reads someone was thinking of |
| `"Principal": "*"` in a **resource** policy without a tight `Condition` | Grants outside the account entirely — worse than any identity-policy wildcard |
| `"NotAction"` or `"NotResource"` in an `Allow` | Grants everything except a list, so every new AWS service is granted on launch |
| A wildcard in the middle of an ARN: `arn:aws:s3:::<org>-*` | Matches buckets that do not exist yet, including one an attacker can name |

Benign, in context: `Resource: "*"` on read-only actions that genuinely have no
resource-level support; `Action: ["s3:GetObject"]` with a wildcard confined to the object
key of one owned bucket; a `Deny` statement with wildcards, which only ever narrows.

The reviewer's question is never "is there a `*`" — that is a grep, and greps are for
detectors. It is: **if this role were fully compromised, what is the largest thing its
holder could do?** Answer that in one sentence. If you cannot, the policy is too broad to
review.

### Checking, rather than assuming

```
aws sts get-caller-identity
aws iam simulate-principal-policy --policy-source-arn <role-arn> --action-names <action> --resource-arns <arn>
aws accessanalyzer list-findings --analyzer-arn <analyzer-arn>
```

The simulator answers "would this call be allowed", including boundary and SCP effects, far
more reliably than reading JSON does. Access Analyzer answers the other question — what is
reachable from outside the account — which no amount of policy reading will tell you.

This skill proposes and reviews. It does not create, attach or delete a role, and neither
should the session that reads it without saying so first.
