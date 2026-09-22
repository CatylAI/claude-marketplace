import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseProjectSettings, checkProjectHooks } from './project-hooks-check.ts';

function repoWith(files: Record<string, string>): string {
  const root = mkdtempSync(join(tmpdir(), 'phc-'));
  for (const [rel, body] of Object.entries(files)) {
    const full = join(root, rel);
    mkdirSync(join(full, '..'), { recursive: true });
    writeFileSync(full, body);
  }
  return root;
}

const withPreToolUse = (commands: string[]) =>
  JSON.stringify({
    hooks: {
      PreToolUse: [{ matcher: '*', hooks: commands.map((command) => ({ type: 'command', command })) }],
    },
  });

describe('parseProjectSettings', () => {
  it('treats unparseable JSON as having no hooks', () => {
    assert.deepEqual(parseProjectSettings('{ not json'), { hasHooks: false, missingCritical: [] });
  });

  it('treats a settings file with no hooks block as having no hooks', () => {
    assert.deepEqual(parseProjectSettings('{"model":"opus"}'), {
      hasHooks: false,
      missingCritical: [],
    });
  });

  // No PreToolUse block means the project did not override anything — whatever is installed at
  // plugin or user level still applies, so there is nothing to warn about.
  it('does not warn when PreToolUse is absent entirely', () => {
    const raw = JSON.stringify({ hooks: { Stop: [] } });
    assert.deepEqual(parseProjectSettings(raw), { hasHooks: true, missingCritical: [] });
  });

  it('warns when an explicit PreToolUse set names none of the guards', () => {
    const result = parseProjectSettings(withPreToolUse(['bash ./scripts/mine.sh']));
    assert.deepEqual(result.missingCritical, ['pre-bash.ts', 'pre-write-edit.ts']);
  });

  // The false positive this arm exists to avoid: a plugin-wired command spells the guards under a
  // path this check cannot know, so any plugin reference has to suppress the warning.
  it('stays quiet when a command references a plugin root', () => {
    for (const cmd of [
      'node ${CLAUDE_PLUGIN_ROOT}/hooks/src/whatever.ts',
      'node /Users/someone/.claude/plugins/cache/x/plugins/y/hooks/src/z.ts',
      'node ~/.claude/hooks/guard.ts',
    ]) {
      assert.deepEqual(parseProjectSettings(withPreToolUse([cmd])).missingCritical, [], cmd);
    }
  });

  it('stays quiet when the guards are named directly', () => {
    const raw = withPreToolUse(['node ./x/pre-bash.ts', 'node ./x/pre-write-edit.ts']);
    assert.deepEqual(parseProjectSettings(raw).missingCritical, []);
  });
});

describe('checkProjectHooks', () => {
  it('finds a root CLAUDE.md', () => {
    const result = checkProjectHooks(repoWith({ 'CLAUDE.md': '# rules' }));
    assert.equal(result.claudeMdPresent, true);
    assert.equal(result.claudeMdLocation, 'root');
  });

  it('finds a CLAUDE.md under .claude/', () => {
    const result = checkProjectHooks(repoWith({ '.claude/CLAUDE.md': '# rules' }));
    assert.equal(result.claudeMdLocation, '.claude');
  });

  it('reports an absent CLAUDE.md', () => {
    const result = checkProjectHooks(repoWith({ 'README.md': 'hi' }));
    assert.equal(result.claudeMdPresent, false);
    assert.equal(result.claudeMdLocation, null);
  });

  it('reads the project settings it finds', () => {
    const root = repoWith({
      'CLAUDE.md': '# rules',
      '.claude/settings.json': withPreToolUse(['bash ./scripts/mine.sh']),
    });
    const result = checkProjectHooks(root);
    assert.equal(result.projectSettingsPresent, true);
    assert.deepEqual(result.settingsMissingCritical, ['pre-bash.ts', 'pre-write-edit.ts']);
  });

  it('reports no settings when the project has none', () => {
    const result = checkProjectHooks(repoWith({ 'CLAUDE.md': '# rules' }));
    assert.equal(result.projectSettingsPresent, false);
    assert.deepEqual(result.settingsMissingCritical, []);
  });
});
