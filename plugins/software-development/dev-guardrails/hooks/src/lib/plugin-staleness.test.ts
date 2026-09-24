import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findStalePlugins, isNewer, latestVersionInMarketplace, pluginsRoot } from './plugin-staleness.ts';

function writeJson(path: string, value: unknown): void {
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, JSON.stringify(value));
}

/** A fake `<config>/plugins` with one marketplace checkout named `mp`. */
function fakeRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'staleness-'));
  mkdirSync(join(root, 'marketplaces', 'mp'), { recursive: true });
  return root;
}

describe('isNewer', () => {
  it('compares dotted versions numerically', () => {
    assert.equal(isNewer('0.10.0', '0.9.9'), true);
    assert.equal(isNewer('1.0.0', '1.0.0'), false);
    assert.equal(isNewer('1.0', '1.0.1'), false);
  });

  it('never calls a SHA-versioned plugin stale', () => {
    assert.equal(isNewer('abc1234', '1.0.0'), false);
  });
});

describe('latestVersionInMarketplace', () => {
  // Regression: the detector used to look only at plugins/<name>/, so a marketplace that nests
  // plugins by category (plugins/<category>/<name>/, as this repo does) never reported anything.
  it('follows the manifest source into a nested category directory', () => {
    const root = fakeRoot();
    const mp = join(root, 'marketplaces', 'mp');
    writeJson(join(mp, '.claude-plugin', 'marketplace.json'), {
      plugins: [{ name: 'dev-guardrails', source: './plugins/software-development/dev-guardrails' }],
    });
    writeJson(
      join(mp, 'plugins', 'software-development', 'dev-guardrails', '.claude-plugin', 'plugin.json'),
      { name: 'dev-guardrails', version: '0.6.0' },
    );
    assert.equal(latestVersionInMarketplace(mp, 'dev-guardrails'), '0.6.0');
  });

  it('prefers the manifest entry version when it has one', () => {
    const root = fakeRoot();
    const mp = join(root, 'marketplaces', 'mp');
    writeJson(join(mp, '.claude-plugin', 'marketplace.json'), {
      plugins: [{ name: 'x', version: '2.0.0', source: './plugins/x' }],
    });
    assert.equal(latestVersionInMarketplace(mp, 'x'), '2.0.0');
  });

  it('falls back to plugins/<name>/ when the manifest has no usable source', () => {
    const root = fakeRoot();
    const mp = join(root, 'marketplaces', 'mp');
    writeJson(join(mp, 'plugins', 'x', '.claude-plugin', 'plugin.json'), { version: '1.2.3' });
    assert.equal(latestVersionInMarketplace(mp, 'x'), '1.2.3');
  });

  it('ignores a source that escapes the checkout', () => {
    const root = fakeRoot();
    const mp = join(root, 'marketplaces', 'mp');
    writeJson(join(root, 'outside', '.claude-plugin', 'plugin.json'), { version: '9.9.9' });
    writeJson(join(mp, '.claude-plugin', 'marketplace.json'), {
      plugins: [{ name: 'x', source: '../../outside' }],
    });
    assert.equal(latestVersionInMarketplace(mp, 'x'), null);
  });
});

describe('findStalePlugins', () => {
  it('reports a loaded version older than the checkout, and nothing for a current one', () => {
    const root = fakeRoot();
    const mp = join(root, 'marketplaces', 'mp');
    writeJson(join(mp, '.claude-plugin', 'marketplace.json'), {
      plugins: [
        { name: 'old', source: './plugins/cat/old' },
        { name: 'current', source: './plugins/cat/current' },
      ],
    });
    writeJson(join(mp, 'plugins', 'cat', 'old', '.claude-plugin', 'plugin.json'), { version: '0.2.0' });
    writeJson(join(mp, 'plugins', 'cat', 'current', '.claude-plugin', 'plugin.json'), { version: '1.0.0' });
    writeJson(join(root, 'installed_plugins.json'), {
      plugins: { 'old@mp': [{ version: '0.1.0' }], 'current@mp': [{ version: '1.0.0' }] },
    });
    assert.deepEqual(findStalePlugins(root), [{ name: 'old@mp', installed: '0.1.0', latest: '0.2.0' }]);
  });

  it('returns nothing when there is no installed_plugins.json', () => {
    assert.deepEqual(findStalePlugins(fakeRoot()), []);
  });
});

describe('pluginsRoot', () => {
  it('honours CLAUDE_CONFIG_DIR', () => {
    assert.equal(pluginsRoot({ CLAUDE_CONFIG_DIR: '/tmp/cfg' }), join('/tmp/cfg', 'plugins'));
  });
});
