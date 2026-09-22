# ${INFRA_DIR}/ — ${PROJECT_NAME} infrastructure

Rules for infrastructure definitions. Root-level rules in `../CLAUDE.md` still apply.

## Tooling

- **Infrastructure tool:** ${INFRA_TOOL}
- **State / backend:** ${STATE_BACKEND}
- **Target environments:** ${ENVIRONMENTS}

## Commands

```bash
# Validate and format
${INFRA_VALIDATE_COMMAND}

# Show what would change
${INFRA_PLAN_COMMAND}

# Apply
${INFRA_APPLY_COMMAND}
```

## Rules

1. **Plan before apply, always.** Read the plan output; an unexpected replacement or
   deletion is a stop-and-ask, never a proceed.
2. **Destructive operations are never run unattended.** Teardown of a shared or persistent
   resource requires explicit confirmation from a human first.
3. **No credentials in these files.** Reference the secret manager; never inline a value.
4. **Environments are parameters, not copies.** A per-environment fork of the same
   definition is a bug waiting to diverge.
5. **Changes to topology are architectural** — record them in `docs/adr/`.

## Local development

${LOCAL_DEV_NOTE}
