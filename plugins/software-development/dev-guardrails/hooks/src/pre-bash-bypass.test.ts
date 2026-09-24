// Regression suite for the bypasses and false positives found in the pre-bash review.
//
// Every case here was reproduced against the regex-over-the-whole-line implementation
// before the gates moved to per-command argv matching. A bypass is a command that does the
// guarded thing and got through; a false positive is ordinary work that was blocked.
// Both kinds matter equally: a gate that blocks ordinary work gets switched off, and
// switching it off takes every other guard down with it.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  evaluateCommitMsg,
  evaluateForgePolicy,
  evaluateGitForce, type GitForceDeps,
  evaluateNoTty,
  evaluateOutboundBash,
  evaluateRmRf,
  evaluateSecretPrint,
  evaluateTerraformBackend,
} from './pre-bash.ts';

// Assembled at runtime so this file never holds a contiguous token-shaped literal.
const FAKE_TOKEN = 'ghp_' + 'A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8';

function deps(over: Partial<GitForceDeps> = {}): GitForceDeps {
  return {
    getBranch: () => 'feature/x',
    isWorkingTreeClean: () => false,
    ...over,
  };
}

// ---------------------------------------------------------------------------------------
// git push --force
// ---------------------------------------------------------------------------------------

describe('bypass: bare force push in every spelling is blocked', () => {
  const cases = [
    'git push -uf origin x', // bundled short flags
    'git push origin +x', // +refspec is a per-ref force
    'git -C repo push --force', // global option before the subcommand
    'git -c core.x=y push --force',
    'git --no-pager push --force',
    'GIT_TRACE=1 git push --force', // env prefix
    'sudo git push --force',
    '/usr/bin/git push --force',
    '"git" push --force',
    'git "push" "--force"',
    "bash -c 'git push --force'",
    'sh -c "git push -f"',
    "bash -lc 'git push -f'",
    "eval 'git push --force'",
    'echo $(git push --force)',
    'echo `git push --force`',
    'cd x\ngit push --force', // newline is a command separator
    'git \\\n  push --force', // line continuation
    '(git push --force)',
    '{ git push --force; }',
    'if true; then git push --force; fi',
    'echo x | xargs git push --force',
    'echo x | xargs -I {} git push --force origin {}',
    'git push --force-with-lease origin a && git push --force origin b',
    'git push --force --force-with-lease origin x',
    "alias gp='git push --force'; gp",
    "bash <<'EOF'\ngit push --force\nEOF",
    "echo 'git push --force' | sh",
    'find . -maxdepth 0 -exec git push --force \\;',
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      const reason = evaluateGitForce(cmd, '/work', deps());
      assert.ok(reason, 'expected a block');
      assert.match(reason, /force/i);
    });
  }

  it('resolves a git alias that expands to a force push', () => {
    const d = deps({ gitAlias: (name) => (name === 'pf' ? 'push --force' : null) });
    assert.ok(evaluateGitForce('git pf origin x', '/work', d));
  });

  it('resolves a shell (!) git alias that runs a force push', () => {
    const d = deps({ gitAlias: (name) => (name === 'yolo' ? '!git push -f' : null) });
    assert.ok(evaluateGitForce('git yolo', '/work', d));
  });

  it('does not consult aliases for builtin subcommands', () => {
    let asked = false;
    const d = deps({ gitAlias: () => { asked = true; return null; } });
    evaluateGitForce('git status', '/work', d);
    assert.equal(asked, false);
  });

  it('blocks any force to a protected branch from a hotfix branch', () => {
    // The source branch's name is no reason to let a push rewrite the protected destination.
    const d = deps({ getBranch: () => 'hotfix/urgent' });
    assert.ok(evaluateGitForce('git push --force origin main', '/work', d));
    assert.ok(evaluateGitForce('git push --force-with-lease origin main', '/work', d));
    assert.ok(evaluateGitForce('git push --force-with-lease origin hotfix/urgent:main', '/work', d));
  });

  it('still allows a lease push of the hotfix branch itself', () => {
    const d = deps({ getBranch: () => 'hotfix/urgent' });
    assert.equal(evaluateGitForce('git push --force-with-lease origin hotfix/urgent', '/work', d), null);
  });
});

describe('bypass: pushes that rewrite or delete a protected branch', () => {
  const onMain = deps({ getBranch: () => 'main' });
  it('lease push with no refspec while on main', () => {
    assert.ok(evaluateGitForce('git push --force-with-lease', '/work', onMain));
    assert.ok(evaluateGitForce('git push --force-with-lease origin', '/work', onMain));
    assert.ok(evaluateGitForce('git push --force-with-lease origin HEAD', '/work', onMain));
  });
  it('deleting a protected branch', () => {
    assert.ok(evaluateGitForce('git push origin :main', '/work', deps()));
    assert.ok(evaluateGitForce('git push --delete origin main', '/work', deps()));
    assert.ok(evaluateGitForce('git push origin -d master', '/work', deps()));
  });
  it('--mirror force-updates every ref', () => {
    assert.ok(evaluateGitForce('git push --mirror', '/work', deps()));
  });
  it('still allows deleting a feature branch', () => {
    assert.equal(evaluateGitForce('git push origin --delete feature/old', '/work', deps()), null);
  });
});

describe('false positive: commands that are not a force push', () => {
  const cases = [
    'git push origin feature/x-f', // a branch name ending in -f
    'git push origin x && rm -f out.txt', // -f belongs to rm
    'git push -o ci.skip origin x',
    'echo "git push --force"',
    'grep -rn "git push -f" docs',
    'git commit -m "docs: never git push --force"',
    'git log -f',
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateGitForce(cmd, '/work', deps()), null);
    });
  }
});

// ---------------------------------------------------------------------------------------
// Discarding working-tree changes
// ---------------------------------------------------------------------------------------

describe('bypass: discarding uncommitted work', () => {
  it('reset --hard behind -C is judged in THAT directory', () => {
    const seen: Array<string | undefined> = [];
    const reason = evaluateGitForce('git -C r reset --hard', '/work', deps({
      isWorkingTreeClean: (cwd) => { seen.push(cwd); return false; },
    }));
    assert.ok(reason);
    assert.deepEqual(seen, ['/work/r']);
  });

  it('reset --hard after `cd` is judged in the cd target', () => {
    const seen: Array<string | undefined> = [];
    evaluateGitForce('cd ../other && git reset --hard', '/work/repo', deps({
      isWorkingTreeClean: (cwd) => { seen.push(cwd); return false; },
    }));
    assert.deepEqual(seen, ['/work/other']);
  });

  for (const cmd of [
    'git checkout .',
    'git checkout ./src',
    'git checkout HEAD -- src/a.ts',
    'git checkout -f main',
    'git restore src/',
    'git restore -- .',
    'git restore --worktree --staged .',
    'git switch --discard-changes main',
    'env GIT_DIR=.git git checkout -- .',
  ]) {
    it(`${JSON.stringify(cmd)} is blocked on a dirty tree`, () => {
      assert.ok(evaluateGitForce(cmd, '/work', deps()));
    });
  }
});

describe('false positive: discards that lose nothing', () => {
  it('checkout -- on a CLEAN tree is allowed (nothing to lose)', () => {
    assert.equal(
      evaluateGitForce('git checkout -- .', '/work', deps({ isWorkingTreeClean: () => true })),
      null,
    );
  });
  for (const cmd of ['git restore --staged .', 'git checkout main', 'git checkout -b feat/x', 'git switch main']) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateGitForce(cmd, '/work', deps()), null);
    });
  }
});

// ---------------------------------------------------------------------------------------
// Conventional commits
// ---------------------------------------------------------------------------------------

describe('bypass: non-conventional commit messages', () => {
  const cases = [
    'git -C x commit -m "bad message"',
    'GIT_AUTHOR_NAME=x git commit -m "bad message"',
    'git commit -am "bad message"',
    'git commit --message "bad message"',
    'git commit --message="bad message"',
    'git commit -m"bad message"',
    'git commit -m bad',
    'git commit --amend --no-edit -m "bad"',
    "cat <<'EOF' > x\nhello\nEOF\ngit commit -m \"bad one\"",
    "git commit -F - <<'EOF'\nbad subject\n\nbody\nEOF",
    "bash -c 'git commit -m \"bad message\"'",
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      const reason = evaluateCommitMsg(cmd, 'feature/x');
      assert.ok(reason, 'expected a block');
      assert.match(reason, /Conventional Commits/);
    });
  }
});

describe('false positive: commit messages git itself or its workflows produce', () => {
  const cases = [
    'git commit -m "Merge branch \'main\' into feat/x"',
    'git commit -m "Revert \\"feat: x\\""',
    'git commit -m "fixup! feat: x"',
    'git commit -m "squash! feat: x"',
    'git commit -m "feat: ok" -m "Body paragraph."',
    "git commit -F - <<'EOF'\nfeat: good subject\n\nbody\nEOF",
    'git commit -m "$MSG"',
    'git log --grep x && git commit -m "feat: ok"',
    'git commit --fixup=HEAD~1',
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateCommitMsg(cmd, 'feature/x'), null);
    });
  }
});

// ---------------------------------------------------------------------------------------
// rm -rf
// ---------------------------------------------------------------------------------------

describe('bypass: rm -rf spellings on macOS', () => {
  const cases = [
    'sudo rm -rf src',
    '/bin/rm -rf src',
    'command rm -rf src',
    'cd x\nrm -rf src',
    "bash -c 'rm -rf src'",
    'find . -name old -exec rm -rf {} +',
    'xargs rm -rf < list',
    'rm -rf dist/../src', // a whitelisted prefix does not excuse a `..` escape
    'rm -rf ./node_modules/../../',
    'rm -rf src/foo-dist/', // substring of a whitelisted name is not the name
    'rm -rf mydist/',
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateRmRf(cmd, 'darwin').kind, 'block');
    });
  }
});

describe('bypass: catastrophic rm -rf targets are blocked on EVERY platform', () => {
  for (const cmd of [
    'rm -rf /',
    'rm -rf /*',
    'rm -rf ~',
    'rm -rf ~/',
    'rm -rf "$HOME"',
    'rm -rf ${HOME}/',
    'rm -rf .',
    'rm -rf ..',
    'rm -rf *',
    'rm -rf /etc',
    'rm -rf --no-preserve-root /',
  ]) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateRmRf(cmd, 'linux').kind, 'block');
    });
  }
});

describe('false positive: ephemeral rm -rf targets', () => {
  for (const cmd of [
    'rm -rf node_modules',
    'rm -rf ./dist',
    'rm -rf packages/app/node_modules',
    'rm -rf .claude/worktrees/feat-x',
    'rm -rf "coverage"',
    'git rm -rf --cached x',
  ]) {
    it(JSON.stringify(cmd), () => {
      assert.notEqual(evaluateRmRf(cmd, 'darwin').kind, 'block');
    });
  }
});

// ---------------------------------------------------------------------------------------
// Gate A — printing a secret
// ---------------------------------------------------------------------------------------

describe('bypass: printing a secret', () => {
  const cases = [
    "bash -c 'echo $GITHUB_TOKEN'",
    "eval 'echo $GITHUB_TOKEN'",
    'echo $GITHUB_TOKEN > /dev/stdout',
    'echo $GITHUB_TOKEN > /dev/tty',
    'printenv GITHUB_TOKEN',
    'aws --profile prod secretsmanager get-secret-value --secret-id x',
    'aws --region us-east-1 ssm get-parameter --name /p --with-decryption',
    'kubectl -n prod get secret app -o yaml',
    'op --account acme read op://v/i/f',
    'sudo cat /root/.aws/credentials',
    "echo 'op read op://v/i/f' | bash",
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      assert.ok(evaluateSecretPrint(cmd), 'expected a block');
    });
  }
});

describe('false positive: ordinary work around secrets', () => {
  const cases = [
    'cat .env.example',
    'cat .env.sample',
    'cat src/config.json',
    'jq .name tsconfig.json',
    'curl -H "Authorization: Bearer $(op read op://v/i/f)" https://api.example.com',
    'docker login -u me -p "$(gh auth token)" ghcr.io',
    'printenv PATH',
    'echo "$GITHUB_TOKEN" > /dev/null',
  ];
  for (const cmd of cases) {
    it(JSON.stringify(cmd), () => {
      assert.equal(evaluateSecretPrint(cmd), null);
    });
  }
});

// ---------------------------------------------------------------------------------------
// Gate C — publishing a secret
// ---------------------------------------------------------------------------------------

describe('bypass: publishing a credential through a forge CLI', () => {
  for (const cmd of [
    `gh release create v1 --notes "${FAKE_TOKEN}"`,
    `gh pr review 1 --comment --body "${FAKE_TOKEN}"`,
    `glab release create v1 --notes "${FAKE_TOKEN}"`,
    `bash -c 'gh pr comment 1 --body "${FAKE_TOKEN}"'`,
    `gh pr create --body-file - <<'EOF'\n${FAKE_TOKEN}\nEOF`,
  ]) {
    it(cmd.slice(0, 40), () => {
      assert.ok(evaluateOutboundBash(cmd));
    });
  }
});

// ---------------------------------------------------------------------------------------
// Terraform, TTY, forge
// ---------------------------------------------------------------------------------------

describe('terraform init', () => {
  const partial = { readTerraformFiles: () => ['terraform {\n  backend "s3" {}\n}\n'] };
  const full = {
    readTerraformFiles: () => ['terraform {\n  backend "s3" {\n    bucket = "state"\n  }\n}\n'],
  };

  it('bypass: -chdir before init', () => {
    assert.ok(evaluateTerraformBackend('terraform -chdir=infra init', '/work', partial));
  });
  it('bypass: env prefix', () => {
    assert.ok(evaluateTerraformBackend('TF_LOG=debug terraform init', '/work', partial));
  });
  it('false positive: -backend-config with a separate value', () => {
    assert.equal(
      evaluateTerraformBackend('terraform init -backend-config backends/dev.tfbackend', '/work', partial),
      null,
    );
  });
  it('false positive: a fully-configured backend needs no -backend-config', () => {
    assert.equal(evaluateTerraformBackend('terraform init', '/work', full), null);
  });
  it('false positive: no backend block at all is local state by design', () => {
    assert.equal(
      evaluateTerraformBackend('terraform init', '/work', { readTerraformFiles: () => ['resource "x" "y" {}'] }),
      null,
    );
  });
  it('reads the -chdir directory, resolved against cwd', () => {
    const seen: string[] = [];
    evaluateTerraformBackend('terraform -chdir=infra init', '/work', {
      readTerraformFiles: (dir) => { seen.push(dir); return []; },
    });
    assert.deepEqual(seen, ['/work/infra']);
  });
});

describe('TTY and forge gates see through prefixes', () => {
  it('bypass: env-prefixed glab ci view', () => {
    assert.ok(evaluateNoTty('GITLAB_HOST=x glab ci view'));
  });
  it('bypass: env-prefixed gh under CLAUDE_FORGE=gitlab', () => {
    assert.ok(evaluateForgePolicy('GH_HOST=x gh pr list', 'gitlab'));
  });
  it('bypass: glab --body inside bash -c', () => {
    assert.ok(evaluateForgePolicy("bash -c 'glab mr create --body x'", 'both'));
  });
});

// ---------------------------------------------------------------------------------------
// Parser-level bypasses and false positives, seen through the gates
// ---------------------------------------------------------------------------------------

describe('bypass: a quoted `<<` no longer swallows the following lines', () => {
  // The old heredoc scanner treated `<< b` inside a quoted string as a heredoc opener and
  // discarded every later line as its body, so whatever those lines ran was invisible.
  it('git push on the next line', () => {
    assert.ok(evaluateGitForce('git commit -m "note: a << b"\ngit push --force', '/work', deps()));
  });
  it('rm -rf on the next line', () => {
    assert.equal(evaluateRmRf('echo "x << y"\nrm -rf src', 'darwin').kind, 'block');
  });
});

describe('bypass: environment dumps by another name', () => {
  it('reading /proc/<pid>/environ', () => {
    assert.ok(evaluateSecretPrint('cat /proc/self/environ'));
  });
  it('env with only assignments and no command prints everything', () => {
    assert.ok(evaluateSecretPrint('env FOO=bar'));
  });
});

describe('false positive: redirections are parsed, not pattern-matched', () => {
  it('`export -p` inside a quoted string is text, not a dump', () => {
    assert.equal(evaluateSecretPrint('echo "use export -p to list"'), null);
  });
  it('`1>file` sends stdout to a file', () => {
    assert.equal(evaluateSecretPrint('echo $GITHUB_TOKEN 1>tok.txt'), null);
  });
  it('a `2>/dev/null` is not an rm target', () => {
    assert.notEqual(evaluateRmRf('rm -rf node_modules/ 2>/dev/null', 'darwin').kind, 'block');
  });
});

// ---------------------------------------------------------------------------------------
// Output shape, end to end
// ---------------------------------------------------------------------------------------

describe('pre-bash.ts output shape', () => {
  const PRE_BASH = join(dirname(fileURLToPath(import.meta.url)), 'pre-bash.ts');

  function run(command: string): { code: number; stdout: string; stderr: string } {
    const env = { ...process.env };
    delete env.CLAUDE_FORGE;
    delete env.CLAUDE_GUARDRAILS_OFF;
    const payload = JSON.stringify({
      hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd: process.cwd(),
    });
    const r = spawnSync(
      process.execPath,
      ['--experimental-strip-types', '--disable-warning=ExperimentalWarning', PRE_BASH],
      { input: payload, encoding: 'utf-8', env },
    );
    return { code: r.status ?? -1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
  }

  it('delivers a non-blocking note as PreToolUse additionalContext JSON', () => {
    // Plain stdout on a PreToolUse exit 0 goes to the debug log only; Claude never sees it.
    const r = run('git switch -c feat/x');
    assert.equal(r.code, 0);
    const out = JSON.parse(r.stdout);
    assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse');
    assert.match(out.hookSpecificOutput.additionalContext, /Sync the base branch/);
  });

  it('never echoes a secret back in a deny reason', () => {
    // The commit gate quotes the subject back in its "Tried:" line.
    const r = run(`git commit -m "use ${FAKE_TOKEN} for ci"`);
    assert.equal(r.code, 2);
    assert.ok(!r.stderr.includes(FAKE_TOKEN), 'the deny reason repeated the secret');
    assert.match(r.stderr, /redacted/);
  });

  it('writes nothing to stdout on a plain allow', () => {
    const r = run('ls -la');
    assert.equal(r.code, 0);
    assert.equal(r.stdout, '');
  });
});

// =======================================================================================
// Second review pass: fixes for the evasions and false positives found in verification.
// Each case below did the guarded thing and got through (or was ordinary work and was
// blocked) on the code as it stood at the start of that pass.
// =======================================================================================

describe('pass 2 — rm -rf: catastrophic targets need only -r, and abbreviations resolve', () => {
  for (const cmd of [
    'rm -r ~',                    // no -f: still destroys the home directory
    'rm -R -- ~',
    'rm --recur --forc ~',        // unambiguous long-option abbreviations
    'rm -rf ${HOME:?}',           // the very idiom the block message recommends
    'rm -rf ${HOME:-/tmp}',
    'rm -rf $HOME/.',
    'rm -rf /usr/*',              // wipes a top-level system directory
    'rm -rf /etc/',
    'rm -rf $PWD',
    'rm -rf "$(pwd)"',
    'rm -rf `pwd`',
    '/bin/r? -rf /',              // glob in the command word
    'r[m] -rf /',
  ]) {
    it(`${JSON.stringify(cmd)} is blocked on every platform`, () => {
      assert.equal(evaluateRmRf(cmd, 'linux').kind, 'block');
    });
  }

  it('rm -r on an ordinary directory is not treated as catastrophic', () => {
    // Recursive without a catastrophic target and without -f: not the unrecoverable sweep.
    assert.equal(evaluateRmRf('rm -r build-output', 'linux').kind, 'allow');
  });
});

describe('pass 2 — git push: abbreviations, brace expansion, inline aliases, send-pack', () => {
  for (const cmd of [
    'git push --mirr origin',
    'git push --force-w origin main',
    'git push --del origin main',
    'git push {-f,origin} main',
    'git push -f{,} origin main',
    "git -c alias.p='push --force' p origin main",
    "git -c alias.p='!git push --force' p",
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=\'push -f\' git p origin x',
    'git send-pack --force origin x',
  ]) {
    it(`${JSON.stringify(cmd)} is blocked`, () => {
      assert.ok(evaluateGitForce(cmd, undefined, deps()), 'expected a block');
    });
  }

  it('--forc stays unresolved (git rejects the ambiguous prefix too), so it is not force', () => {
    // force / force-with-lease / force-if-includes all start with --forc: no unique match.
    // A non-force push to a feature branch is allowed.
    assert.equal(evaluateGitForce('git push --forc origin feature/x', undefined, deps()), null);
  });
});

describe('pass 2 — git: more ways to discard work', () => {
  const dirty = (over: Partial<GitForceDeps> = {}): GitForceDeps =>
    deps({ pathExists: () => true, ...over });

  for (const cmd of [
    'git checkout f.txt',            // an existing file, no `--`
    'git checkout HEAD f.txt',       // ref + pathspec
    'git clean -fdx',
    'git clean --force',
    'git checkout-index -f -a',
    'git read-tree -u --reset HEAD',
    'git reset --har',               // abbreviation
    'git switch --discard main',     // abbreviation
  ]) {
    it(`${JSON.stringify(cmd)} is blocked on a dirty tree`, () => {
      assert.ok(evaluateGitForce(cmd, '/work', dirty()), 'expected a block');
    });
  }

  it('git checkout <branch> is not a discard (the name is not a file)', () => {
    assert.equal(evaluateGitForce('git checkout main', '/work', deps({ pathExists: () => false })), null);
  });
  it('git clean -n (dry run) lists, it does not delete', () => {
    assert.equal(evaluateGitForce('git clean -n', '/work', deps({ pathExists: () => false })), null);
  });

  // Pins the fail-CLOSED direction: an unresolvable command directory (`cd "$X"`) must read
  // as dirty, not clean. A mutation flipping this let `cd "$X" && git reset --hard` through.
  it('an unresolvable command directory is treated as dirty (fails closed)', () => {
    const clean = () => { throw new Error('isWorkingTreeClean must not be consulted for a null dir'); };
    assert.ok(evaluateGitForce('cd "$UNKNOWN" && git reset --hard', '/work', deps({ isWorkingTreeClean: clean })));
  });
});

describe('pass 2 — commit message: long-option abbreviations', () => {
  it('git commit --mess=... is read as --message', () => {
    assert.ok(evaluateCommitMsg("git commit --mess='bad message'", 'feature/x'));
  });
});

describe('pass 2 — printing secrets: forms the gate used to miss', () => {
  for (const cmd of [
    "kubectl get secret x -ojsonpath='{.data}'",
    'kubectl get secret x -ojson',
    'cat <<< "$GITHUB_TOKEN"',
    'tr -d x <<< "$GITHUB_TOKEN"',
    'declare -p GITHUB_TOKEN',
    'typeset -p AWS_SECRET_ACCESS_KEY',
    'gh auth status -t',
    'gh auth status --show-token',
    'aws configure get aws_secret_access_key',
    'aws configure export-credentials',
    'aws sts get-session-token',
    '< .env cat',
    'cat < .env',
    'cat .e*',
    'tac .env',
    'sort .env',
  ]) {
    it(`${JSON.stringify(cmd)} is blocked`, () => {
      assert.ok(evaluateSecretPrint(cmd), 'expected a block');
    });
  }

  // A literal `$VAR` inside single quotes is text bash never expands: not a printed secret.
  for (const cmd of [
    "echo 'Export $GITHUB_TOKEN before running'",
    "printf 'usage: set $API_KEY\\n'",
    "sed -i 's/password=.*/password=${DB_PASSWORD}/' config.ini",
  ]) {
    it(`false positive: ${JSON.stringify(cmd)} is allowed`, () => {
      assert.equal(evaluateSecretPrint(cmd), null);
    });
  }

  // `env | cut -c1-200` prints whole NAME=value lines; only `-d= -f1` (names) is safe. A
  // mutation that made stripsValues always true let the character-slice dump through.
  it('env | cut -c1-200 is a dump (character mode carries values)', () => {
    assert.ok(evaluateSecretPrint('env | cut -c1-200'));
  });
  it('env | cut -d= -f1 is allowed (names only)', () => {
    assert.equal(evaluateSecretPrint('env | cut -d= -f1'), null);
  });
});

describe('pass 2 — publishing a secret split across quoted words', () => {
  it('a token concatenated from adjacent quoted words is caught', () => {
    const head = FAKE_TOKEN.slice(0, 4);
    const tail = FAKE_TOKEN.slice(4);
    assert.ok(evaluateOutboundBash(`gh pr create --title t --body '${head}'"${tail}"`));
  });
});
