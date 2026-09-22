// Gate A, secret STORES — the rules in pre-bash.ts that had no coverage at all.
//
// The thesis, and the reason these belong in one suite: RETRIEVING a secret into the
// transcript is the leak, and which store it came from changes nothing about that. A
// vault, a cloud secret manager, a key vault, a CI/CD variable store and a forge's token
// API all hand back plaintext, so they all get the same treatment. Any rule that reads a
// credential out of somewhere and lets it reach stdout belongs here, tested the same way.
//
// A variable STORE deserves particular emphasis. A single-secret retrieval discloses one
// value; one call to a variable store returns every credential the project holds, and a
// substring filter over the response does not help — the filter matches on the KEY while
// the response carries the VALUE beside it. Masking is a job-log display rule, not an API
// one, so a masked variable is returned in plaintext just the same.
//
// Kept out of pre-bash.test.ts on purpose. This suite is almost entirely string literals
// naming retrieval commands, and Gate A matches on exactly those strings; isolating them
// keeps the main suite readable and keeps a future reader from mistaking a fixture for a
// command someone intended to run.

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { evaluateSecretPrint, SECRET_PRINT_ALLOW_MARKER } from './pre-bash.ts';

const RETRIEVAL = 'secret-retrieval-print';

describe('Gate A: every secret store is a retrieval, whichever one it is', () => {
  it('blocks reading a secret from a password manager', () => {
    const d = evaluateSecretPrint('op read op://vault/deploy/token');
    assert.ok(d, 'an unconsumed `op read` hands back plaintext');
    assert.equal(d.rule, RETRIEVAL);
    assert.ok(evaluateSecretPrint('op item get deploy --fields password'));
  });

  it('blocks reading a secret from a cloud secret manager', () => {
    assert.equal(
      evaluateSecretPrint('aws secretsmanager get-secret-value --secret-id prod/db')?.rule,
      RETRIEVAL,
    );
    assert.ok(evaluateSecretPrint('aws ssm get-parameter --name /prod/api-token --with-decryption'));
    assert.ok(evaluateSecretPrint('gcloud secrets versions access latest --secret=deploy-token'));
  });

  it('blocks reading a secret from a self-hosted vault', () => {
    assert.equal(evaluateSecretPrint('vault kv get secret/data/prod/api')?.rule, RETRIEVAL);
    assert.ok(evaluateSecretPrint('vault read secret/prod/api'));
  });

  it('blocks reading a secret from a managed key vault', () => {
    assert.equal(
      evaluateSecretPrint('az keyvault secret show --name deploy-token --vault-name prod-kv')?.rule,
      RETRIEVAL,
    );
    assert.ok(evaluateSecretPrint('az keyvault secret download --name deploy-token --vault-name prod-kv'));
  });

  it('blocks the other stores that return plaintext on read', () => {
    assert.ok(evaluateSecretPrint('kubectl get secret app-secrets -o yaml'));
    assert.ok(evaluateSecretPrint('doppler secrets get DEPLOY_TOKEN'));
    assert.ok(evaluateSecretPrint('pass show services/api'));
    assert.ok(evaluateSecretPrint('security find-generic-password -s deploy -w'));
    assert.ok(evaluateSecretPrint('aws ecr get-login-password --region us-east-1'));
    assert.ok(evaluateSecretPrint('gcloud auth print-access-token'));
  });
});

describe('Gate A: a CI/CD variable store returns every credential at once', () => {
  it('blocks a bare read of the variables API on either forge', () => {
    assert.equal(evaluateSecretPrint('glab api "/projects/1/variables"')?.rule, RETRIEVAL);
    assert.equal(evaluateSecretPrint('gh api "/repos/acme/app/actions/variables"')?.rule, RETRIEVAL);
  });

  it('blocks the key-filtered form — the filter matches the KEY and prints the VALUE', () => {
    assert.ok(
      evaluateSecretPrint('glab api "/projects/1/variables" | grep -i token'),
      'filtering by key does not stop the value beside it being printed',
    );
    assert.ok(evaluateSecretPrint('gh api "/repos/acme/app/actions/variables" | grep -i token'));
  });

  it('blocks the jq form, which still streams values through the pipe', () => {
    assert.ok(evaluateSecretPrint('glab api /projects/1/variables | jq .'));
    assert.ok(evaluateSecretPrint('gh api /repos/acme/app/actions/variables | jq -r ".[].value"'));
  });

  it('blocks reading a single named variable — masking governs job logs, not the API', () => {
    assert.ok(evaluateSecretPrint('glab api "/projects/1/variables/DEPLOY_TOKEN"'));
    assert.ok(evaluateSecretPrint('gh api "/repos/acme/app/actions/variables/DEPLOY_TOKEN"'));
  });

  it('blocks token minting, where the response is the only copy that will ever exist', () => {
    // A minted token is never shown again, so printing it is worse than printing a secret
    // that can be re-read: the transcript becomes the system of record for a live credential.
    assert.ok(evaluateSecretPrint('glab api --method POST /projects/1/access_tokens -f name=ci'));
    assert.ok(evaluateSecretPrint('glab api --method POST /projects/1/deploy_tokens'));
    assert.ok(evaluateSecretPrint('gh api --method POST /users/acme/personal_access_tokens'));
  });

  it('blocks the forge CLI variable subcommands on BOTH forges', () => {
    // These hooks are forge-neutral by default, so a rule that covered only one CLI would
    // leave half the users of this plugin with no gate at all.
    assert.ok(evaluateSecretPrint('glab variable get DEPLOY_TOKEN'));
    assert.ok(evaluateSecretPrint('glab variable list'));
    assert.ok(evaluateSecretPrint('glab variable export'));
    assert.ok(evaluateSecretPrint('gh variable get DEPLOY_TOKEN'));
    assert.ok(evaluateSecretPrint('gh variable list'));
  });

  it('does not fire on unrelated API paths that merely resemble the secret ones', () => {
    // The cost of a false positive here is the whole hook being switched off, which would
    // take the destructive-git guards down with it.
    assert.equal(evaluateSecretPrint('glab api /projects/1/merge_requests/2'), null);
    assert.equal(evaluateSecretPrint('glab api /projects/1/pipelines'), null);
    assert.equal(evaluateSecretPrint('gh api /repos/acme/app/pulls/2'), null);
    assert.equal(evaluateSecretPrint('gh api /repos/acme/app/actions/runs'), null);
  });
});

// The sanctioned forms must keep working. A gate that refuses the correct pattern as well
// as the wrong one gets switched off wholesale, which is worse than having no gate.
describe('Gate A: the sanctioned retrieval forms stay allowed', () => {
  it('allows capture into a variable — assigned, never printed', () => {
    assert.equal(evaluateSecretPrint('TOKEN="$(op read op://vault/deploy/token)"'), null);
    assert.equal(
      evaluateSecretPrint('TOKEN=$(aws secretsmanager get-secret-value --secret-id prod/db)'),
      null,
    );
    assert.equal(evaluateSecretPrint('VARS="$(glab api /projects/1/variables)"'), null);
  });

  it('allows a redirect to a file — a file never reaches the transcript', () => {
    assert.equal(evaluateSecretPrint('op read op://vault/deploy/token > "$HOME/.config/tok"'), null);
    assert.equal(evaluateSecretPrint('glab api /projects/1/variables > vars.json'), null);
  });

  it('allows a pipe into a consumer that takes the credential on stdin', () => {
    assert.equal(
      evaluateSecretPrint('aws ecr get-login-password | docker login --password-stdin r.example.com'),
      null,
    );
  });

  it('allows the deliberate opt-out marker, which stays visible in the transcript', () => {
    assert.equal(
      evaluateSecretPrint(`glab variable list ${SECRET_PRINT_ALLOW_MARKER}`),
      null,
    );
  });
});

// A heredoc body is DATA, not a command. Writing a test or a doc that merely MENTIONS a
// retrieval command must not trip the rule — the gate obstructing its own documentation is
// how a gate gets switched off. This very file is the demonstration: it names every
// retrieval command in the package.
describe('Gate A: a heredoc body does not trip the retrieval rule', () => {
  const write = "cat > notes.md <<'EOF'\nRun glab variable get DEPLOY_TOKEN to read it.\nEOF";

  it('allows writing a file whose CONTENT names a retrieval command', () => {
    assert.equal(evaluateSecretPrint(write), null);
  });

  it('still blocks the same retrieval when it is actually executed', () => {
    assert.ok(evaluateSecretPrint('glab variable get DEPLOY_TOKEN'));
  });

  it('never attributes a block to an unrelated segment of the command line', () => {
    const d = evaluateSecretPrint(write);
    if (d) assert.doesNotMatch(d.message, /Tried:\s+cat >/, 'must not blame the file write');
  });
});
