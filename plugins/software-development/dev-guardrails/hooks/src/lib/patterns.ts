// Shared regex patterns used by the Bash PreToolUse guard.

// --- forge CLIs -------------------------------------------------------------------
// Matched on the SUBCOMMAND as well as the binary, so a directory named `gh` or a
// variable assignment never counts as an invocation.
export const GH_CLI = /(^|[;&|]\s*)gh\s+(pr|issue|api|repo|release|run|workflow|auth|config|gist|label|project|ssh-key|status|variable|secret|codespace|extension|gpg-key|search|cache|ruleset|attestation)/;
export const GLAB_CLI = /(^|[;&|]\s*)glab\s+(mr|issue|api|repo|release|ci|pipeline|auth|config|label|snippet|variable|schedule|cluster|incident|iteration|token|user|alias|changelog|ask|job|stack)/;

// `--body` is the GitHub CLI's flag and `--description` is the GitLab CLI's. Each is an
// error on the other tool, and the error surfaces late — after a branch is pushed. The
// guard matches them per command segment (see evaluateForgePolicy), not with a regex over
// the whole line, so a compound command cannot cross-blame one CLI for the other's flag.

// --- git ---------------------------------------------------------------------------
export const GIT_COMMIT = /(^|[;&|]\s*)git\s+commit/;
export const GIT_COMMAND = /(^|[;&|]\s*)git\s+/;

// --- terraform ----------------------------------------------------------------------
export const TERRAFORM_INIT = /(^|[;&|]\s*)terraform\s+init\b/;

// --- conventional commits -------------------------------------------------------------
export const CONVENTIONAL_COMMIT = /^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_/-]+\))?!?:\s.+/;

// --- shell scripts ---------------------------------------------------------------------
// A hardcoded interpreter path. Soft-warn only: `#!/usr/bin/env bash` is portable across
// macOS (where /bin/bash is 3.2) and Linux, and `/usr/bin/bash` does not exist on macOS.
export const HARDCODED_BASH_PATH = /^#!\s*\/bin\/bash\b|^#!\s*\/usr\/bin\/bash\b/;

// --- credential shapes used by the PostToolUse advisory pass ---------------------------
// Blocking on credential content is pre-write-edit.ts's job, via lib/secrets.ts. This one
// pattern is here because post-write-edit reports an AWS key id in a config file it has
// already scanned for other reasons, and reaching into the secrets module for a single
// regex would imply the two gates share a definition. They do not.
export const AWS_KEY = /AKIA[0-9A-Z]{16}/;

// --- language security smells (advisory, PostToolUse) ------------------------------------
// Each one is a shape a scanner would flag, cheap enough to check inline on a write. None of
// them blocks: a PostToolUse hook fires after the bytes are on disk, so a block there would
// stop the next step while leaving the file exactly as written.
export const SHELL_TRUE = /shell\s*=\s*True/;
export const FSTRING_SQL = /f['"](SELECT|INSERT|UPDATE|DELETE).*\{/i;
export const INNER_HTML = /innerHTML\s*=/;
export const DANGEROUS_SET_INNER_HTML = /dangerouslySetInnerHTML/;
export const V_HTML = /v-html\s*=/;
export const EVAL_CALL = /eval\s*\(/;

// --- terraform security smells (advisory, PostToolUse) -----------------------------------
// TF_WILDCARD_IAM and TF_WILDCARD_RESOURCE are reported only TOGETHER. Either alone is
// ordinary: a policy that allows many actions on one resource, or one action across a
// resource class, is how most policies are written. Both at once is the admin grant.
export const TF_PUBLICLY_ACCESSIBLE = /publicly_accessible\s*=\s*true/;
export const TF_OPEN_CIDR = /cidr_blocks\s*=\s*\["0\.0\.0\.0\/0"\]/;
export const TF_IAM_USER = /aws_iam_user\s+/;
export const TF_UNENCRYPTED = /storage_encrypted\s*=\s*false/;
export const TF_PUBLIC_S3 = /block_public_acls\s*=\s*false/;
export const TF_WILDCARD_IAM = /Action\s*=\s*"\*"/;
export const TF_WILDCARD_RESOURCE = /Resource\s*=\s*"\*"/;
