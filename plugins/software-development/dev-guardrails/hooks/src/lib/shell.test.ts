import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exec, execArgv, execCapture, execArgvCapture, commandExists } from './shell.ts';

describe('exec', () => {
  it('returns trimmed stdout', () => {
    assert.equal(exec('echo hello'), 'hello');
  });

  it('returns null instead of throwing on a non-zero exit', () => {
    assert.equal(exec('exit 3'), null);
  });

  it('returns null instead of throwing when the program does not exist', () => {
    assert.equal(exec('definitely-not-a-real-binary-xyz'), null);
  });

  it('honours a shell feature, which is the only reason to use it', () => {
    assert.equal(exec('echo a && echo b'), 'a\nb');
  });
});

describe('execArgv', () => {
  it('returns trimmed stdout', () => {
    assert.equal(execArgv('echo', ['hello']), 'hello');
  });

  it('returns null rather than throwing when the program does not exist', () => {
    assert.equal(execArgv('definitely-not-a-real-binary-xyz', []), null);
  });

  // THE WHOLE POINT OF THIS FUNCTION. The same string is code through `exec` and data through
  // `execArgv`, and every caller that interpolates a path or a branch name depends on that.
  it('passes a command substitution through as literal text, executing nothing', () => {
    const marker = join(mkdtempSync(join(tmpdir(), 'shell-')), 'pwned');
    const hostile = `$(touch ${marker})`;

    const out = execArgv('echo', [hostile]);

    assert.equal(out, hostile);
    assert.equal(existsSync(marker), false, 'the substitution was executed');
  });

  it('passes shell metacharacters through as literal text', () => {
    assert.equal(execArgv('echo', ['a; b | c && d']), 'a; b | c && d');
  });
});

describe('execCapture', () => {
  it('reports a success', () => {
    const r = execCapture('echo ok');
    assert.equal(r.exitCode, 0);
    assert.equal(r.stdout, 'ok');
  });

  it('reports a non-zero exit code rather than throwing', () => {
    const r = execCapture('exit 4');
    assert.equal(r.exitCode, 4);
  });

  it('captures stderr', () => {
    const r = execCapture('echo boom >&2; exit 1');
    assert.equal(r.exitCode, 1);
    assert.equal(r.stderr, 'boom');
  });
});

describe('execArgvCapture', () => {
  it('reports a success', () => {
    const r = execArgvCapture('echo', ['ok']);
    assert.equal(r.exitCode, 0);
    assert.equal(r.stdout, 'ok');
  });

  it('reports a failure rather than throwing', () => {
    assert.notEqual(execArgvCapture('definitely-not-a-real-binary-xyz', []).exitCode, 0);
  });

  it('does not let an argument reach a shell', () => {
    const marker = join(mkdtempSync(join(tmpdir(), 'shell-')), 'pwned');
    execArgvCapture('echo', [`$(touch ${marker})`]);
    assert.equal(existsSync(marker), false);
  });
});

describe('commandExists', () => {
  it('finds a program that is certainly present', () => {
    assert.equal(commandExists('echo'), true);
  });

  it('does not find one that is not', () => {
    assert.equal(commandExists('definitely-not-a-real-binary-xyz'), false);
  });
});
