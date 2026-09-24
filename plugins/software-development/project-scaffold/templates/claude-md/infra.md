---
paths:
  - "infrastructure/**"
---

# Infrastructure rules

- Run `make fmt validate` after editing, and `make plan-<env>` before any apply. Read the plan: an
  unexpected replace or destroy means stop and ask.
- Apply only on explicit human confirmation, one environment at a time via its own target.
- Environment differences live in `infrastructure/terraform/environments/<env>.tfvars`, not in
  copied module code.
- Credentials come from ${SECRETS_SOURCE}; never inline a value in a `.tf` or `.tfvars` file.
- State backend: ${STATE_BACKEND}.
