# OIDC subject-claim details

Verify against current docs: these change with the platform, so check the provider's documentation before relying on a date or format here.

## GitHub OIDC immutable subject claims

Repositories created after 2026-07-15, and repositories renamed or transferred after that date,
emit the immutable `sub` format `repo:<org>@<org-id>/<repo>@<repo-id>:…`; older repositories
keep `repo:<org>/<repo>:…` unless opted in. Not on GitHub Enterprise Server. Source: GitHub
docs, "OpenID Connect reference" → "Immutable subject claims".
