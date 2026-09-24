import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { systemMessageJson } from './output.ts';

// Claude Code parses a hook's stdout as JSON only when it is one object; a field in the wrong
// place is dropped without an error. This pins the shape the docs define.
describe('systemMessageJson', () => {
  it('puts systemMessage at the top level', () => {
    assert.deepEqual(JSON.parse(systemMessageJson('heads up')), { systemMessage: 'heads up' });
  });

  it('produces a single line, so stdout stays one JSON object', () => {
    assert.ok(!systemMessageJson('a\nb').includes('\n'));
  });
});
