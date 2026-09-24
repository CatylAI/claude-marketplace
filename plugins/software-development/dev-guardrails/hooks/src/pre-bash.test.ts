import { describe, it, test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_FORGE,
  DEFAULT_TICKET_PATTERN,
  RMRF_ALLOW_MARKER,
  ALLOW_MARKER,
  FORCE_PUSH_ALLOW_MARKER,
  SECRET_PRINT_ALLOW_MARKER,
  evaluateBranchCreation,
  evaluateCommitMsg,
  evaluateCommitOnProtected,
  evaluateForgePolicy,
  evaluateGitForce, type GitForceDeps,
  evaluateNoTty,
  evaluateOutboundBash,
  evaluateRmRf,
  evaluateSecretPrint,
  evaluateTerraformBackend,
  extractTicket,
  protectedBranches,
  resolveForge,
  targetsProtectedBranch,
  ticketPattern,
} from './pre-bash.ts';
import { assertAllowlistSafe } from './lib/secrets.ts';

// ---------------------------------------------------------------------------------------
// Forge policy
//
// The rule this suite exists to pin: the DEFAULT blocks NEITHER CLI. A hook that refuses
// the user's primary forge CLI out of the box breaks every session, so `both` (and any
// unset/unrecognised value) must stay permissive. The single-forge modes block only the
// OTHER forge's CLI, never their own.
// ---------------------------------------------------------------------------------------

const GH_CMD = 'gh pr create --title "x" --body "y"';
const GLAB_CMD = 'glab mr list';

describe('resolveForge', () => {
  it('defaults to `both` when CLAUDE_FORGE is unset', () => {
    assert.equal(resolveForge({}), 'both');
    assert.equal(DEFAULT_FORGE, 'both');
  });

  it('defaults to `both` for an empty or unrecognised value', () => {
    // An unrecognised value is NOT a declaration. Reading it as one would block a CLI on
    // the strength of a typo.
    for (const raw of ['', '   ', 'githib', 'bitbucket', 'yes']) {
      assert.equal(resolveForge({ CLAUDE_FORGE: raw }), 'both', `raw=${JSON.stringify(raw)}`);
    }
  });

  it('accepts the three known values, case- and whitespace-insensitively', () => {
    assert.equal(resolveForge({ CLAUDE_FORGE: 'github' }), 'github');
    assert.equal(resolveForge({ CLAUDE_FORGE: ' GitLab ' }), 'gitlab');
    assert.equal(resolveForge({ CLAUDE_FORGE: 'BOTH' }), 'both');
  });
});

describe('evaluateForgePolicy — `both` (the default) blocks neither CLI', () => {
  it('allows gh', () => {
    assert.equal(evaluateForgePolicy(GH_CMD, 'both'), null);
  });
  it('allows glab', () => {
    assert.equal(evaluateForgePolicy(GLAB_CMD, 'both'), null);
  });
  it('allows every gh subcommand the old always-block rule refused', () => {
    for (const cmd of ['gh pr view 12', 'gh issue list', 'gh api repos/o/r', 'gh repo clone o/r', 'gh run watch']) {
      assert.equal(evaluateForgePolicy(cmd, 'both'), null, cmd);
    }
  });
});

describe('evaluateForgePolicy — `github` blocks glab only', () => {
  it('blocks glab', () => {
    const reason = evaluateForgePolicy(GLAB_CMD, 'github');
    assert.ok(reason, 'glab must be blocked when the project is GitHub');
    assert.match(reason, /configured for GitHub/);
    assert.match(reason, /gh pr create --body/);
  });
  it('does NOT block gh', () => {
    assert.equal(evaluateForgePolicy(GH_CMD, 'github'), null);
  });
});

describe('evaluateForgePolicy — `gitlab` blocks gh only', () => {
  it('blocks gh', () => {
    const reason = evaluateForgePolicy(GH_CMD, 'gitlab');
    assert.ok(reason, 'gh must be blocked when the project is GitLab');
    assert.match(reason, /configured for GitLab/);
    assert.match(reason, /glab mr create --description/);
  });
  it('does NOT block glab', () => {
    assert.equal(evaluateForgePolicy(GLAB_CMD, 'gitlab'), null);
  });
});

describe('evaluateForgePolicy — flag guidance follows the selected forge', () => {
  it('blocks glab --body when glab is permitted', () => {
    for (const forge of ['gitlab', 'both'] as const) {
      const reason = evaluateForgePolicy('glab mr create --body "text"', forge);
      assert.ok(reason, `forge=${forge}`);
      assert.match(reason, /--body is a GitHub CLI flag/);
    }
  });

  it('blocks gh --description when gh is permitted', () => {
    for (const forge of ['github', 'both'] as const) {
      const reason = evaluateForgePolicy('gh pr create --description "text"', forge);
      assert.ok(reason, `forge=${forge}`);
      assert.match(reason, /--description is a GitLab CLI flag/);
    }
  });

  it('does not confuse the two CLIs in one compound command', () => {
    // `gh pr create --body` is CORRECT. Matching --body anywhere in a line that also
    // mentions glab would blame glab for gh's perfectly legal flag.
    assert.equal(evaluateForgePolicy('gh pr create --body "x" && glab mr list', 'both'), null);
  });

  it('the gh --body form, which is correct, is never blocked', () => {
    assert.equal(evaluateForgePolicy('gh pr create --body "x"', 'both'), null);
    assert.equal(evaluateForgePolicy('gh pr create --body "x"', 'github'), null);
  });
});

// ---------------------------------------------------------------------------------------
// Ticket pattern and protected branches — both configurable, both with generic defaults
// ---------------------------------------------------------------------------------------

describe('ticketPattern / extractTicket', () => {
  it('defaults to a generic KEY-123 shape, not a specific tracker prefix', () => {
    assert.equal(ticketPattern({}), DEFAULT_TICKET_PATTERN);
    assert.equal(extractTicket('feature/PROJ-42-add-thing', ticketPattern({})), 'PROJ-42');
    assert.equal(extractTicket('fix/AB1-7', ticketPattern({})), 'AB1-7');
  });

  it('honours CLAUDE_TICKET_PATTERN', () => {
    const pattern = ticketPattern({ CLAUDE_TICKET_PATTERN: 'ISSUE_[0-9]+' });
    assert.equal(extractTicket('wip/ISSUE_88', pattern), 'ISSUE_88');
    assert.equal(extractTicket('wip/PROJ-42', pattern), null);
  });

  it('returns null when the branch carries no key', () => {
    assert.equal(extractTicket('main'), null);
    assert.equal(extractTicket('chore/cleanup'), null);
  });

  it('falls back to the default rather than throwing on an invalid pattern', () => {
    // A broken regex in someone's shell profile must not take every Bash call down.
    assert.equal(extractTicket('feature/PROJ-42', '([unterminated'), 'PROJ-42');
  });
});

describe('protected branches', () => {
  it('defaults to main and master', () => {
    assert.deepEqual(protectedBranches({}), ['main', 'master']);
    assert.deepEqual(protectedBranches({ CLAUDE_PROTECTED_BRANCHES: '  ' }), ['main', 'master']);
  });

  it('honours CLAUDE_PROTECTED_BRANCHES', () => {
    assert.deepEqual(protectedBranches({ CLAUDE_PROTECTED_BRANCHES: 'trunk, release' }), ['trunk', 'release']);
  });

  it('matches every refspec form but not a path suffix', () => {
    const b = ['main', 'master'];
    assert.equal(targetsProtectedBranch('git push origin main', b), true);
    assert.equal(targetsProtectedBranch('git push origin HEAD:main', b), true);
    assert.equal(targetsProtectedBranch('git push origin +main', b), true);
    assert.equal(targetsProtectedBranch('git push origin refs/heads/master', b), true);
    // `feature/main` is its own branch; treating it as protected both blocks a legitimate
    // push and silently exempts it from the real rule.
    assert.equal(targetsProtectedBranch('git push origin feature/main', b), false);
  });
});

// ---------------------------------------------------------------------------------------
// Destructive git
// ---------------------------------------------------------------------------------------

function deps(over: Partial<GitForceDeps> = {}): GitForceDeps {
  return {
    getBranch: () => 'feature/PROJ-1',
    isWorkingTreeClean: () => true,
    ...over,
  };
}

test('a non-git command is allowed', () => {
  assert.equal(evaluateGitForce('ls -la', undefined, deps()), null);
});

test('push --force is blocked on a normal branch', () => {
  const reason = evaluateGitForce('git push --force origin feature/PROJ-1', undefined, deps());
  assert.ok(reason && reason.includes('git push --force is prohibited'));
});

test('push --force-with-lease is ALLOWED on a non-protected branch', () => {
  assert.equal(
    evaluateGitForce('git push --force-with-lease origin feature/PROJ-1', undefined, deps()),
    null,
  );
});

test('push --force-with-lease to a protected branch is blocked', () => {
  const reason = evaluateGitForce('git push --force-with-lease origin main', undefined, deps());
  assert.ok(reason && /protected branch/.test(reason));
});

test('the protected list is configurable end to end', () => {
  const reason = evaluateGitForce(
    'git push --force-with-lease origin trunk', undefined, deps(), ['trunk'],
  );
  assert.ok(reason && /protected branch \(trunk\)/.test(reason));
  // …and main is no longer protected once the list is overridden.
  assert.equal(
    evaluateGitForce('git push --force-with-lease origin main', undefined, deps(), ['trunk']),
    null,
  );
});

test('the force-push escape marker lifts the force arms only', () => {
  assert.equal(
    evaluateGitForce(`git push --force origin feature/x ${FORCE_PUSH_ALLOW_MARKER}`, undefined, deps()),
    null,
  );
  assert.equal(
    evaluateGitForce(`git push --force origin feature/x ${ALLOW_MARKER}`, undefined, deps()),
    null,
    'the generic marker also waives it',
  );
  // …but a reset --hard on the same line is still judged.
  const reason = evaluateGitForce(
    `git reset --hard ${FORCE_PUSH_ALLOW_MARKER}`, undefined, deps({ isWorkingTreeClean: () => false }),
  );
  assert.ok(reason && /reset --hard/.test(reason));
});

test('reset --hard is judged against the COMMAND cwd, not the process cwd', () => {
  const seen: Array<string | undefined> = [];
  const reason = evaluateGitForce('git reset --hard', '/dirty/tree', deps({
    isWorkingTreeClean: (cwd) => { seen.push(cwd); return false; },
  }));
  assert.ok(reason && reason.includes('git reset --hard'));
  assert.deepEqual(seen, ['/dirty/tree']);
});

test('reset --hard is allowed when the tree is clean', () => {
  assert.equal(evaluateGitForce('git reset --hard', '/clean', deps()), null);
});

test('the working tree is not consulted for a plain push', () => {
  let called = false;
  evaluateGitForce('git push origin feature/x', undefined, deps({
    isWorkingTreeClean: () => { called = true; return true; },
  }));
  assert.equal(called, false);
});

test('checkout -- and restore . are blocked on a dirty tree', () => {
  // On a clean tree there is nothing to lose, so they are allowed: see pre-bash-bypass.test.ts.
  const dirty = deps({ isWorkingTreeClean: () => false });
  assert.ok(evaluateGitForce('git checkout -- .', undefined, dirty));
  assert.ok(evaluateGitForce('git restore .', undefined, dirty));
});

// ---------------------------------------------------------------------------------------
// rm -rf
// ---------------------------------------------------------------------------------------

describe('evaluateRmRf', () => {
  it('blocks a recursive force delete of a source path on macOS', () => {
    const d = evaluateRmRf('rm -rf src/old-module', 'darwin');
    assert.equal(d.kind, 'block');
  });

  it('warns instead of blocking off macOS, and does not suggest a macOS-only binary', () => {
    const d = evaluateRmRf('rm -rf src/old-module', 'linux');
    assert.equal(d.kind, 'allow-with-warning');
    if (d.kind === 'allow-with-warning') assert.match(d.message, /macOS-only/);
  });

  it('allows an ephemeral target with a warning', () => {
    const d = evaluateRmRf('rm -rf node_modules/', 'darwin');
    assert.equal(d.kind, 'allow-with-warning');
  });

  it('requires a UNANIMOUS whitelist match', () => {
    const d = evaluateRmRf('rm -rf dist/ && rm -rf /etc/hosts', 'darwin');
    assert.equal(d.kind, 'block');
  });

  it('reads flags PER SEGMENT so a sibling -R does not make an rm -f recursive', () => {
    const d = evaluateRmRf('grep -R pattern src && rm -f /tmp/out.md', 'darwin');
    assert.equal(d.kind, 'allow');
  });

  it('honours both the specific and the generic escape marker', () => {
    for (const marker of [RMRF_ALLOW_MARKER, ALLOW_MARKER]) {
      const d = evaluateRmRf(`rm -rf src/old ${marker}`, 'darwin');
      assert.equal(d.kind, 'allow-with-warning', marker);
    }
  });

  it('is not fooled by a marker quoted inside the command', () => {
    // A quoted span is not a comment. If it were honoured, any command echoing this
    // plugin's own documentation would open the gate.
    const d = evaluateRmRf(`rm -rf src/old --note "${RMRF_ALLOW_MARKER}"`, 'darwin');
    assert.equal(d.kind, 'block');
  });
});

// ---------------------------------------------------------------------------------------
// Commit messages
// ---------------------------------------------------------------------------------------

describe('evaluateCommitMsg', () => {
  it('allows a conventional message', () => {
    assert.equal(evaluateCommitMsg('git commit -m "feat(api): add filter"'), null);
    assert.equal(evaluateCommitMsg("git commit -m 'fix: handle null'"), null);
    assert.equal(evaluateCommitMsg('git commit -m "feat(auth)!: rotate tokens"'), null);
  });

  it('blocks a non-conventional message', () => {
    const reason = evaluateCommitMsg('git commit -m "fixed the thing"');
    assert.ok(reason && /Conventional Commits/.test(reason));
  });

  it('names the branch ticket as the suggested scope when there is one', () => {
    const reason = evaluateCommitMsg('git commit -m "stuff"', 'feature/PROJ-42-x');
    assert.ok(reason);
    assert.match(reason, /feat\(PROJ-42\)/);
  });

  it('falls back to a component scope when the branch has no ticket', () => {
    const reason = evaluateCommitMsg('git commit -m "stuff"', 'chore/cleanup');
    assert.ok(reason);
    assert.match(reason, /feat\(api\)/);
  });

  it('bypasses --amend --no-edit and an editor-written message', () => {
    assert.equal(evaluateCommitMsg('git commit --amend --no-edit'), null);
    assert.equal(evaluateCommitMsg('git commit'), null);
  });

  it('allows when the message cannot be read (a repo-side hook is the safety net)', () => {
    assert.equal(evaluateCommitMsg('git commit -m $MSG'), null);
  });

  it('reads the subject line out of a heredoc message', () => {
    const cmd = 'git commit -m "$(cat <<\'EOF\'\nbroken subject\n\nbody\nEOF\n)"';
    const reason = evaluateCommitMsg(cmd);
    assert.ok(reason && /broken subject/.test(reason));
  });
});

describe('evaluateCommitOnProtected', () => {
  it('notes, and does not block, a commit on a protected branch', () => {
    const note = evaluateCommitOnProtected('git commit -m "feat: x"', 'main');
    assert.ok(note && note.startsWith('ℹ️'));
  });
  it('says nothing on a feature branch', () => {
    assert.equal(evaluateCommitOnProtected('git commit -m "feat: x"', 'feature/x'), null);
  });
});

// ---------------------------------------------------------------------------------------
// Terraform, TTY, branch creation
// ---------------------------------------------------------------------------------------

describe('the smaller guards', () => {
  it('blocks a bare terraform init on a partial backend and allows the sanctioned forms', () => {
    const partial = { readTerraformFiles: () => ['terraform {\n  backend "s3" {}\n}'] };
    assert.ok(evaluateTerraformBackend('terraform init', '/work', partial));
    assert.equal(evaluateTerraformBackend('terraform init -backend-config=backends/dev.tfbackend', '/work', partial), null);
    assert.equal(evaluateTerraformBackend('terraform init -upgrade -backend=false', '/work', partial), null);
    assert.equal(evaluateTerraformBackend('terraform plan', '/work', partial), null);
  });

  it('blocks the TTY-only pipeline viewers and allows their non-interactive siblings', () => {
    assert.ok(evaluateNoTty('glab ci view'));
    assert.equal(evaluateNoTty('glab ci view-log'), null);
    assert.equal(evaluateNoTty('glab ci status'), null);
  });

  it('nudges on branch creation only', () => {
    assert.ok(evaluateBranchCreation('git switch -c feature/x'));
    assert.ok(evaluateBranchCreation('git checkout -b feature/x'));
    assert.ok(evaluateBranchCreation('git worktree add ../wt feature/x'));
    assert.equal(evaluateBranchCreation('git switch main'), null);
  });
});

// ---------------------------------------------------------------------------------------
// Gate A — never print a secret
// ---------------------------------------------------------------------------------------

describe('evaluateSecretPrint', () => {
  it('blocks the incident: ${VAR:-x} yields the VALUE when VAR is set', () => {
    const d = evaluateSecretPrint('echo "TF_TOKEN set: ${TF_TOKEN_example_com:-no}"');
    assert.ok(d);
    assert.equal(d.rule, 'unsafe-expansion');
  });

  it('allows every safe expansion form', () => {
    for (const cmd of [
      'echo "TOKEN: ${GITHUB_TOKEN:+set}"',
      'echo "len ${#GITHUB_TOKEN}"',
      'echo "prefix ${GITHUB_TOKEN:0:4}"',
    ]) {
      assert.equal(evaluateSecretPrint(cmd), null, cmd);
    }
  });

  it('does NOT fire on ordinary work — the false positives that get a gate deleted', () => {
    for (const cmd of [
      'export GITHUB_TOKEN="$OTHER"',
      'curl -H "Authorization: Bearer $GITHUB_TOKEN" https://example.com',
      'GITHUB_TOKEN="$X" make deploy',
      'echo "$GITHUB_TOKEN" > "$HOME/.config/tokenfile"',
      'for pat in "${patterns[@]}"; do echo "$pat"; done',
    ]) {
      assert.equal(evaluateSecretPrint(cmd), null, cmd);
    }
  });

  it('blocks an unconsumed retrieval and allows a captured or piped one', () => {
    const d = evaluateSecretPrint('op read op://vault/item/field');
    assert.ok(d);
    assert.equal(d.rule, 'secret-retrieval-print');
    assert.equal(evaluateSecretPrint('TOKEN="$(op read op://vault/item/field)"'), null);
    assert.equal(
      evaluateSecretPrint('gh auth token | docker login ghcr.io -u me --password-stdin'),
      null,
    );
  });

  it('blocks an unfiltered env dump and allows the name-only idioms', () => {
    const d = evaluateSecretPrint('env');
    assert.ok(d);
    assert.equal(d.rule, 'env-dump');
    assert.equal(evaluateSecretPrint('env | cut -d= -f1'), null);
    assert.equal(evaluateSecretPrint('env | grep -c AWS'), null);
  });

  it('blocks printing a credential file and allows the counting idioms it recommends', () => {
    const d = evaluateSecretPrint('cat .env');
    assert.ok(d);
    assert.equal(d.rule, 'credential-file-print');
    // The gate must not block its own remediation.
    assert.equal(evaluateSecretPrint('grep -c . .env'), null);
    assert.equal(evaluateSecretPrint('cut -d= -f1 .env'), null);
    // Searching FOR the word is not reading a credential file.
    assert.equal(evaluateSecretPrint('grep -rn credentials docs/'), null);
  });

  it('blocks printing Snowflake connection files and .p8 private keys', () => {
    for (const cmd of [
      'cat ~/.snowflake/connections.toml',
      'cat "$HOME/.snowflake/config.toml"',
      'head -20 ~/.snowflake/connections.toml',
      'grep password ~/.snowflake/connections.toml',
      'cat snowflake_key.p8',
      'cat ~/.snowflake/keys/*.p8',
      'base64 < ~/.snowflake/keys/agent.p8',
      // Case-insensitive extension, and connections.toml wherever $SNOWFLAKE_HOME puts it.
      'cat KEY.P8',
      'cat ~/.snowflake/keys/Agent.P8',
      'cat $SNOWFLAKE_HOME/connections.toml',
      'less /opt/snow/connections.toml',
    ]) {
      const d = evaluateSecretPrint(cmd);
      assert.ok(d, cmd);
      assert.equal(d.rule, 'credential-file-print', cmd);
    }
  });

  it('does not block ordinary work near Snowflake files', () => {
    for (const cmd of [
      // The public half is meant to be read and pasted into ALTER USER.
      'cat ~/.snowflake/keys/agent.p8.pub',
      'cat ~/.snowflake/keys/agent.pub',
      // Counting and name-only idioms, and a config.toml outside ~/.snowflake.
      'grep -c . ~/.snowflake/connections.toml',
      'cat pyproject/config.toml',
      // Searching FOR the extension is not reading a key.
      'grep -rn "\\.p8" .gitignore',
      'snow connection list',
      'cat ~/.snowflake/keys/AGENT.P8.PUB',
      'grep -c . $SNOWFLAKE_HOME/connections.toml',
      'cat connections.toml.example',
      // Known gap, by design: interpreters are out of scope (dev-guardrails README,
      // "What these hooks are, and are not").
      'python3 -c "print(open(\'/root/.snowflake/connections.toml\').read())"',
    ]) {
      assert.equal(evaluateSecretPrint(cmd), null, cmd);
    }
  });

  it('blocks openssl writing a private key to stdout', () => {
    for (const cmd of [
      'openssl pkey -in ~/.snowflake/keys/agent.p8',
      'openssl rsa -in ~/.snowflake/keys/agent.p8',
      'openssl pkey -in key.pem -text -noout',
      'openssl pkcs8 -in key.p8 -out /dev/stdout',
      'openssl genrsa 2048',
      'openssl genrsa 2048 | cat',
      'openssl pkey < key.p8',
    ]) {
      const d = evaluateSecretPrint(cmd);
      assert.ok(d, cmd);
      assert.equal(d.rule, 'private-key-print', cmd);
    }
  });

  it('allows openssl calls that print only public or no key material', () => {
    for (const cmd of [
      'openssl rsa -in ~/.snowflake/keys/agent.p8 -pubout -out ~/.snowflake/keys/agent.pub',
      'openssl pkey -in key.p8 -pubout',
      'openssl rsa -pubin -in agent.pub -outform DER | openssl dgst -sha256 -binary | openssl enc -base64',
      'openssl rsa -in key.p8 -check -noout',
      'openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake/keys/agent.p8',
      'openssl pkey -in key.p8 > new.pem',
      'openssl x509 -in cert.pem -text -noout',
      'openssl dgst -sha256 file.txt',
      `openssl pkey -in key.p8 ${SECRET_PRINT_ALLOW_MARKER}`,
    ]) {
      assert.equal(evaluateSecretPrint(cmd), null, cmd);
    }
  });

  it('honours the escape marker on the rules that have one, but not on env-dump', () => {
    assert.equal(evaluateSecretPrint(`cat .env ${SECRET_PRINT_ALLOW_MARKER}`), null);
    assert.equal(evaluateSecretPrint(`cat .env ${ALLOW_MARKER}`), null);
    const d = evaluateSecretPrint(`env ${SECRET_PRINT_ALLOW_MARKER}`);
    assert.ok(d, 'env-dump has no escape');
    assert.equal(d.rule, 'env-dump');
  });

  it('blocks an unquoted heredoc that would expand a secret into its body', () => {
    const d = evaluateSecretPrint('cat <<EOF\ntoken=$GITHUB_TOKEN\nEOF');
    assert.ok(d);
    assert.equal(d.rule, 'unsafe-expansion-heredoc');
    // A quoted delimiter performs no expansion at all.
    assert.equal(evaluateSecretPrint("cat <<'EOF'\ntoken=$GITHUB_TOKEN\nEOF"), null);
  });
});

// ---------------------------------------------------------------------------------------
// Gate C — never publish a secret
// ---------------------------------------------------------------------------------------

describe('evaluateOutboundBash', () => {
  // Assembled at runtime so this file never contains a contiguous token-shaped literal.
  const FAKE_TOKEN = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8';

  it('blocks a credential in a pull-request body on either forge', () => {
    assert.ok(evaluateOutboundBash(`gh pr create --body "use ${FAKE_TOKEN} to auth"`));
    assert.ok(evaluateOutboundBash(`glab mr create --description "use ${FAKE_TOKEN}"`));
  });

  it('allows a note that DESCRIBES a leak without quoting the value', () => {
    assert.equal(
      evaluateOutboundBash('gh pr create --body "a credential is hardcoded at config.py:12"'),
      null,
    );
  });

  it('ignores a token that is not heading outbound', () => {
    assert.equal(evaluateOutboundBash(`echo ${FAKE_TOKEN} > /dev/null`), null);
  });
});

test('the secret-name allowlist cannot cancel a secret substring', () => {
  assert.doesNotThrow(assertAllowlistSafe);
});

// ---------------------------------------------------------------------------------------
// End to end: the hook is WIRED, and the forge default really is permissive
//
// A decision function can be complete, fully unit-tested and never called. These spawn the
// real hook the way Claude Code does and assert the real exit code.
// ---------------------------------------------------------------------------------------

describe('pre-bash.ts as Claude Code runs it', () => {
  const PRE_BASH = join(dirname(fileURLToPath(import.meta.url)), 'pre-bash.ts');

  function runHook(command: string, forge?: string): { code: number; stderr: string } {
    const env = { ...process.env };
    delete env.CLAUDE_FORGE;
    delete env.CLAUDE_GUARDRAILS_OFF;
    if (forge !== undefined) env.CLAUDE_FORGE = forge;
    const payload = JSON.stringify({ tool_name: 'Bash', tool_input: { command }, cwd: process.cwd() });
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', PRE_BASH],
      { input: payload, encoding: 'utf-8', env },
    );
    return { code: r.status ?? -1, stderr: r.stderr ?? '' };
  }

  it('allows `gh pr create` with CLAUDE_FORGE UNSET', () => {
    const r = runHook('gh pr create --title "x" --body "y"');
    assert.equal(r.code, 0, `expected allow, got ${r.code}: ${r.stderr}`);
  });

  it('allows `glab mr list` with CLAUDE_FORGE UNSET', () => {
    assert.equal(runHook('glab mr list').code, 0);
  });

  it('blocks gh only under CLAUDE_FORGE=gitlab', () => {
    assert.equal(runHook('gh pr create --title "x" --body "y"', 'gitlab').code, 2);
    assert.equal(runHook('glab mr list', 'gitlab').code, 0);
  });

  it('blocks glab only under CLAUDE_FORGE=github', () => {
    assert.equal(runHook('glab mr list', 'github').code, 2);
    assert.equal(runHook('gh pr create --title "x" --body "y"', 'github').code, 0);
  });

  it('blocks a secret print end to end', () => {
    const r = runHook('echo "${GITHUB_TOKEN:-unset}"');
    assert.equal(r.code, 2);
    assert.match(r.stderr, /BLOCKED/);
  });

  it('allows a non-Bash tool call untouched', () => {
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', PRE_BASH],
      { input: JSON.stringify({ tool_name: 'Read', tool_input: {} }), encoding: 'utf-8' },
    );
    assert.equal(r.status, 0);
  });

  it('blocks a command too long to check inside the timeout', () => {
    // A generated command far larger than any hand-typed one: parsing it could outrun the
    // hook timeout, and a timed-out hook lets the command PROCEED. So it is denied outright.
    const huge = 'echo ' + 'x'.repeat(70 * 1024) + ' && git push -f';
    const r = runHook(huge);
    assert.equal(r.code, 2);
    assert.match(r.stderr, /too long to check/);
  });

  it('a normal-size command with many substitutions still finishes fast', () => {
    const many = 'echo ' + '$(date) '.repeat(4000) + '; git push -f';
    const started = Date.now();
    assert.equal(runHook(many).code, 2); // still blocked (the force push is seen)
    assert.ok(Date.now() - started < 8000, 'parsing regressed to quadratic');
  });

  for (const [label, stdin] of [
    ['empty stdin', ''],
    ['not JSON', 'not json at all'],
    ['JSON null', 'null'],
    ['JSON array', '[]'],
    ['JSON number', '5'],
    ['a non-string command', JSON.stringify({ tool_name: 'Bash', tool_input: { command: 5 } })],
    ['a non-object tool_input', JSON.stringify({ tool_name: 'Bash', tool_input: 'x' })],
  ] as const) {
    it(`does not crash on ${label} — it allows and exits 0`, () => {
      const r = spawnSync(
        process.execPath,
        ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', PRE_BASH],
        { input: stdin, encoding: 'utf-8' },
      );
      assert.equal(r.status, 0, `exit ${r.status}: ${r.stderr}`);
    });
  }
});
