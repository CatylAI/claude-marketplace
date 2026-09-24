// Unit tests for the command parser every pre-bash gate reads through.
//
// The gates' own suites (pre-bash*.test.ts) test the decisions. These pin the parser
// behaviour those decisions rest on, so a parser change that would silently widen or
// narrow every gate at once fails here first, with a readable message.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  blankUnexpanded, expandBraces, extractHeredocs, hasAllowMarker, parseCommand, shellQuote,
  trailingComment, unquote,
} from './bash-parse.ts';

const heads = (cmd: string): Array<string | null> => parseCommand(cmd).map((c) => c.head);

describe('unquote', () => {
  it('removes quotes and escapes the way the shell does', () => {
    assert.equal(unquote(`"a b"`), 'a b');
    assert.equal(unquote(`'a "b"'`), 'a "b"');
    assert.equal(unquote(`a\\ b`), 'a b');
    assert.equal(unquote(`"say \\"hi\\""`), 'say "hi"');
    assert.equal(unquote(`'it'\\''s'`), "it's");
    assert.equal(unquote(`$'a\\nb'`), 'a\nb');
    assert.equal(unquote(`-m"feat: x"`), '-mfeat: x');
  });
  it('round-trips through shellQuote', () => {
    for (const w of ['plain', 'a b', "it's", '$HOME', ';']) assert.equal(unquote(shellQuote(w)), w);
  });
});

describe('parseCommand: finding every command', () => {
  it('splits on ; && || | & and newlines', () => {
    assert.deepEqual(heads('a; b && c || d | e & f\ng'), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
  });
  it('joins line continuations instead of splitting on them', () => {
    const [c] = parseCommand('git \\\n  push --force');
    assert.equal(c!.head, 'git');
    assert.deepEqual(c!.argv, ['push', '--force']);
  });
  it('resolves through assignments, wrappers and keywords', () => {
    assert.deepEqual(heads('FOO=1 BAR=2 make'), ['make']);
    assert.deepEqual(heads('sudo -u root rm x'), ['rm']);
    assert.deepEqual(heads('timeout -s KILL 30 git push'), ['git']);
    assert.deepEqual(heads('xargs -I {} -n 1 git push'), ['git']);
    assert.deepEqual(heads('env -u X FOO=1 node a.js'), ['node']);
    assert.deepEqual(heads('if true; then git push; fi'), ['true', 'git', null]);
    assert.deepEqual(heads('(cd x && git push)'), ['cd', 'git']);
    assert.deepEqual(heads('/usr/bin/git status'), ['git']);
  });
  it('does not treat `command -v` as running its argument', () => {
    assert.deepEqual(heads('command -v git'), ['command']);
  });
  it('recurses into substitutions, -c scripts, eval, find -exec, aliases and piped scripts', () => {
    assert.ok(heads('echo "$(op read x)"').includes('op'));
    assert.ok(heads('echo `op read x`').includes('op'));
    assert.ok(heads("bash -c 'git push'").includes('git'));
    assert.ok(heads("bash -o pipefail -c 'git push'").includes('git'));
    assert.ok(heads("eval 'git push'").includes('git'));
    assert.ok(heads('find . -exec rm -rf {} +').includes('rm'));
    assert.ok(heads("alias g='git push'").includes('git'));
    assert.ok(heads("echo 'git push' | sh").includes('git'));
    assert.ok(heads("bash <<'EOF'\ngit push\nEOF").includes('git'));
    assert.ok(heads("bash <<< 'git push'").includes('git'));
  });
  it('does not run a heredoc body fed to a non-shell', () => {
    assert.ok(!heads("cat > notes.md <<'EOF'\ngit push --force\nEOF").includes('git'));
  });
});

describe('parseCommand: output routing', () => {
  const only = (cmd: string) => parseCommand(cmd)[0]!;
  it('recognises stdout redirected to a file, in every spelling', () => {
    for (const cmd of ['echo x > f', 'echo x >> f', 'echo x 1>f', 'echo x>f', 'echo x &> f', 'echo x >| f']) {
      assert.equal(only(cmd).redirectsStdout, true, cmd);
    }
  });
  it('does not count stderr, fd duplication or a transcript device as a file', () => {
    for (const cmd of ['echo x 2>f', 'echo x >&2', 'echo x > /dev/stdout', 'echo x > /dev/tty', 'echo x 2>&1']) {
      assert.equal(only(cmd).redirectsStdout, false, cmd);
    }
  });
  it('removes redirections from argv', () => {
    assert.deepEqual(only('rm -rf dist 2>/dev/null').argv, ['-rf', 'dist']);
  });
  it('records who receives a substitution', () => {
    const inner = parseCommand('curl -H "X: $(op read x)" u').find((c) => c.head === 'op')!;
    assert.equal(inner.substitutedInto, 'curl');
    const assigned = parseCommand('T="$(op read x)"').find((c) => c.head === 'op')!;
    assert.equal(assigned.captured, true);
  });
  it('tracks top-level cd for later commands', () => {
    const cmds = parseCommand('cd a && cd b; git status');
    assert.deepEqual(cmds.find((c) => c.head === 'git')!.cdArgs, ['a', 'b']);
  });
});

describe('extractHeredocs', () => {
  it('ignores `<<` inside quotes', () => {
    const { command, heredocs } = extractHeredocs('echo "a << b"\ngit push');
    assert.equal(heredocs.length, 0);
    assert.match(command, /git push/);
  });
  it('finds a heredoc opened inside a double-quoted substitution', () => {
    const { heredocs } = extractHeredocs(`git commit -m "$(cat <<'EOF'\nfeat: x\nEOF\n)"`);
    assert.equal(heredocs.length, 1);
    assert.equal(heredocs[0]!.body, 'feat: x');
    assert.equal(heredocs[0]!.quoted, true);
  });
  it('does not mistake a here-string for a heredoc', () => {
    assert.equal(extractHeredocs('cat <<< "EOF"\nnext').heredocs.length, 0);
  });
});

describe('hasAllowMarker / trailingComment — a marker cannot be smuggled', () => {
  const MARKER = '# claude-allow';

  it('honours a real trailing comment', () => {
    assert.equal(hasAllowMarker('git push -f # claude-allow', MARKER), true);
    assert.equal(hasAllowMarker('git push -f #claude-allow', MARKER), true); // spacing normalised
  });

  it('ignores a marker inside a quoted string, even across newlines', () => {
    // Quote state is carried across the newline: the second line is still inside the quote.
    assert.equal(hasAllowMarker("git commit -m 'feat: x\n# claude-allow' && git push -f", MARKER), false);
    assert.equal(hasAllowMarker('gh pr create --body "notes\n# claude-allow"', MARKER), false);
  });

  it('only the last non-empty line counts', () => {
    assert.equal(hasAllowMarker('echo x # claude-allow\ngit push -f', MARKER), false);
  });

  it('the comment must equal the marker, not merely start with it', () => {
    assert.equal(hasAllowMarker('git push -f # claude-allow-force-push-nope', MARKER), false);
  });

  it('a heredoc body documenting the marker is not a waiver', () => {
    assert.equal(hasAllowMarker("git commit -F - <<'EOF'\n# claude-allow\nEOF", MARKER), false);
  });

  it('trailingComment returns null on an unterminated quote', () => {
    assert.equal(trailingComment("echo 'unterminated # claude-allow"), null);
  });
});

describe('expandBraces — comma brace expansion the shell performs before argv', () => {
  it('splits a comma group into separate words', () => {
    assert.deepEqual(expandBraces('{-f,origin}'), ['-f', 'origin']);
    assert.deepEqual(expandBraces('push{,-mirror}'), ['push', 'push-mirror']);
  });
  it('leaves a word with no comma group unchanged', () => {
    assert.deepEqual(expandBraces('origin'), ['origin']);
    assert.deepEqual(expandBraces('{1..3}'), ['{1..3}']); // ranges are not comma groups
  });
  it('does not expand inside quotes', () => {
    assert.deepEqual(expandBraces(`'{-f,origin}'`), [`'{-f,origin}'`]);
  });
  it('parseCommand surfaces the expanded flag in argv', () => {
    const push = parseCommand('git push {-f,origin} main').find((c) => c.head === 'git');
    assert.ok(push!.argv.includes('-f'));
  });
});

describe('blankUnexpanded — single-quoted and $\'…\' spans expand to nothing', () => {
  it('blanks single quotes but keeps double-quoted references', () => {
    assert.equal(blankUnexpanded(`echo '$X' "$Y"`).includes('$X'), false);
    assert.equal(blankUnexpanded(`echo '$X' "$Y"`).includes('$Y'), true);
  });
  it('blanks ANSI-C $\'…\'', () => {
    assert.equal(blankUnexpanded(`printf $'$X\\n'`).includes('$X'), false);
  });
});
