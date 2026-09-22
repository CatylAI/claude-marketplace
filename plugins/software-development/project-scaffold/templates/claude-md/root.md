# ${PROJECT_NAME}

> ${ONE_LINE_DESCRIPTION}

## Stack

- **Language:** ${LANGUAGE} ${LANGUAGE_VERSION}
- **Package manager:** ${PACKAGE_MANAGER}
- **Framework:** ${FRAMEWORK}
- **Infrastructure:** ${INFRA_SUMMARY}

## Commands

```bash
# Install dependencies
${INSTALL_COMMAND}

# Run locally
${RUN_COMMAND}

# Build
${BUILD_COMMAND}

# Test
${TEST_COMMAND}

# Lint and format
${LINT_COMMAND}

# The one command that must pass before a change is done
${VERIFY_COMMAND}
```

## Layout

| Path | Purpose |
| --- | --- |
| `${SOURCE_DIR}/` | Application source |
| `${TEST_DIR}/` | Test suite |
| `${INFRA_DIR}/` | Infrastructure definitions |
| `docs/` | Documentation |

## Architecture and decisions

Architectural decisions are recorded in `docs/adr/`; `docs/adr/README.md` is the index.
Changing a decision an ADR records means amending that ADR in the same change.

## Working rules

1. **Tests:** every test must pass before a change is considered done. Fix failures; do not
   skip, mark expected-to-fail, or delete them to get green.
2. **Secrets:** never in source, config, or a commit message. Use the project's secret
   manager or environment variables.
3. **Scope:** a change does one thing. Unrelated cleanups go in their own change.
4. **Commits:** ${COMMIT_CONVENTION}
5. **Branches:** ${BRANCH_CONVENTION}

## Common mistakes

<!-- Add project-specific gotchas here as they are discovered. This section is the highest
     value part of this file: it is what stops the same mistake being made twice. -->
