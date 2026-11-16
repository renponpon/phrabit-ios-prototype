import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { classifyCommandFailure, distributionSpec, targetSettingsArguments, validateExecution } from './ios-testflight.mjs';

const approved = { GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: 'renponpon/phrabit-ios-prototype', GITHUB_REF: 'refs/heads/main', EXPECTED_COMMIT: 'a'.repeat(40), GITHUB_SHA: 'a'.repeat(40), RUNNER_TEMP: '/tmp/runner' };
const appUuid = '11111111-1111-1111-1111-111111111111';
const controlUuid = '22222222-2222-2222-2222-222222222222';

test('requires the exact approved main commit in the dedicated repository', () => { validateExecution(approved); });
test('rejects another repository or branch', () => {
  assert.throws(() => validateExecution({ ...approved, GITHUB_REPOSITORY: 'example/other' }));
  assert.throws(() => validateExecution({ ...approved, GITHUB_REF: 'refs/heads/other' }));
});
test('rejects missing or mismatched full commit SHA', () => {
  assert.throws(() => validateExecution({ ...approved, EXPECTED_COMMIT: 'aaaaaaa' }));
  assert.throws(() => validateExecution({ ...approved, GITHUB_SHA: 'b'.repeat(40) }));
});
test('rejects execution outside GitHub hosted context', () => {
  assert.throws(() => validateExecution({ ...approved, GITHUB_ACTIONS: 'false' }));
  assert.throws(() => validateExecution({ ...approved, RUNNER_TEMP: '' }));
});
test('keeps per-target manual signing profiles separate', () => {
  const spec = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1');
  assert.equal(spec.targets.PhrabitCapture.settings.base.PROVISIONING_PROFILE_SPECIFIER, appUuid);
  assert.equal(spec.targets.PhrabitCaptureControl.settings.base.PROVISIONING_PROFILE_SPECIFIER, controlUuid);
  assert.equal(spec.settings.base.CODE_SIGN_STYLE, 'Manual');
  for (const target of ['PhrabitCapture', 'PhrabitCaptureControl']) {
    assert.equal(spec.targets[target].settings.base.CODE_SIGN_STYLE, 'Manual');
    assert.equal(spec.targets[target].settings.base.CODE_SIGN_IDENTITY, 'Apple Distribution');
    assert.equal(spec.targets[target].settings.base['CODE_SIGN_IDENTITY[sdk=iphoneos*]'], 'Apple Distribution');
    assert.equal(spec.targets[target].settings.base.CURRENT_PROJECT_VERSION, '1.1');
    assert.equal(spec.targets[target].settings.base.MARKETING_VERSION, '0.1.0');
  }
});
test('rejects invalid team, duplicate profiles, and invalid build versions', () => {
  assert.throws(() => distributionSpec('invalid', appUuid, controlUuid, '1.1'));
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, appUuid, '1.1'));
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '0.1'));
});
test('distribution workflow stays manually gated and separate from unsigned CI', () => {
  const workflow = readFileSync(new URL('../.github/workflows/ios-testflight.yml', import.meta.url), 'utf8');
  assert.match(workflow, /environment: ios-testflight/);
  assert.match(workflow, /expected_commit:/);
  assert.match(workflow, /default: false/);
  assert.match(workflow, /if: \$\{\{ always\(\) \}\}/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /runs-on: macos-26-intel/);
  assert.doesNotMatch(workflow, /^\s+(push|pull_request|schedule):/m);
  assert.doesNotMatch(workflow, /upload-artifact|actions\/cache|allowProvisioningUpdates/);
});

test('diagnostics disclose only fixed categories or Apple error codes', () => {
  assert.equal(classifyCommandFailure('User interaction is not allowed'), 'KEYCHAIN_ACCESS');
  assert.equal(classifyCommandFailure('unable to build chain to self-signed root'), 'CERTIFICATE_TRUST_CHAIN');
  assert.equal(classifyCommandFailure('upload rejected ITMS-90161'), 'ITMS-90161');
  assert.equal(classifyCommandFailure('synthetic private command details'), 'PRIVATE_DIAGNOSTICS_SUPPRESSED');
});

test('queries each explicit target rather than assuming scheme includes dependencies', () => {
  for (const target of ['PhrabitCapture', 'PhrabitCaptureControl']) {
    const argumentsList = targetSettingsArguments(target);
    assert.equal(argumentsList[argumentsList.indexOf('-target') + 1], target);
    assert.ok(argumentsList.includes('-showBuildSettings'));
    assert.ok(!argumentsList.includes('-scheme'));
  }
  assert.throws(() => targetSettingsArguments('UnexpectedTarget'));
});
