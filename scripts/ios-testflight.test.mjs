import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { approvedPreviewProjectDigest, classifyCommandFailure, distributionSpec, previewAuthPrivacyCategories, previewAuthSettings, targetSettingsArguments, validateExecution } from './ios-testflight.mjs';

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
    assert.equal(spec.targets[target].info.properties.CFBundleVersion, '$(CURRENT_PROJECT_VERSION)');
    assert.equal(spec.targets[target].info.properties.CFBundleShortVersionString, '$(MARKETING_VERSION)');
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

test('pins the approved Preview project using a complete SHA-256 digest', () => {
  assert.match(approvedPreviewProjectDigest, /^[a-f0-9]{64}$/);
});

test('preview auth remains off by default and rejects incomplete or unrelated configuration', () => {
  assert.equal(previewAuthSettings({}), undefined);
  assert.equal(previewAuthSettings({ IOS_PREVIEW_AUTH_ONLY: 'false' }), undefined);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_AUTH_ONLY: 'yes' }), /Invalid preview mode/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_AUTH_ONLY: 'true' }), /Approved isolated Preview project only/);
  assert.throws(() => previewAuthSettings({
    IOS_PREVIEW_AUTH_ONLY: 'true',
    IOS_PREVIEW_PROJECT_REF: 'abcdefghijklmnopqrst',
    IOS_PREVIEW_PUBLISHABLE_KEY: 'sb_publishable_synthetic_example_key'
  }), /Approved isolated Preview project only/);
});

test('capture check is opt-in and cannot be signed outside Preview auth-only mode', () => {
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_CAPTURE_CHECK: 'true' }), /requires Preview auth-only mode/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_AUTH_ONLY: 'false', IOS_PREVIEW_CAPTURE_CHECK: 'true' }), /requires Preview auth-only mode/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_CAPTURE_CHECK: 'yes' }), /Invalid capture check mode/);
});

test('local mock recording requires both Preview flags', () => {
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_MOCK_RECORDING: 'yes' }), /Invalid mock recording mode/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_AUTH_ONLY: 'true', IOS_PREVIEW_MOCK_RECORDING: 'true' }), /requires Preview capture check/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_CAPTURE_CHECK: 'true', IOS_PREVIEW_MOCK_RECORDING: 'true' }), /requires Preview auth-only mode/);
  const settings = { ProjectRef: 'abcdefghijklmnopqrst', PublishableKey: 'sb_publishable_synthetic_example_key', ConnectionCheck: 'capture-edge-v1', LocalMockRecording: 'true' };
  const targets = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', settings).targets;
  assert.deepEqual(targets.PhrabitCapture.info.properties.PhrabitPreviewAuthOnly, settings);
  assert.match(targets.PhrabitCapture.info.properties.NSMicrophoneUsageDescription, /音声は送信せず/);
  assert.equal(targets.PhrabitCaptureControl.info.properties.PhrabitPreviewAuthOnly, undefined);
});

test('new-path diagnostics requires auth and excludes all other recording and check modes', () => {
  const audioDiagnostics = { IOS_PREVIEW_AUDIO_ACCESS_ONLY: 'true' };
  assert.throws(() => previewAuthSettings(audioDiagnostics), /requires Preview auth-only mode/);
  assert.throws(() => previewAuthSettings({ IOS_PREVIEW_AUDIO_ACCESS_ONLY: 'yes' }), /Invalid audio diagnostics mode/);
  for (const flag of ['IOS_PREVIEW_CAPTURE_CHECK', 'IOS_PREVIEW_MOCK_RECORDING']) {
    assert.throws(() => previewAuthSettings({ ...audioDiagnostics, IOS_PREVIEW_AUTH_ONLY: 'true', [flag]: 'true' }), /cannot include legacy diagnostics or recording/);
  }
});

test('new-path diagnostics produces the no-recording marker in both targets while keeping auth app-only', () => {
  const settings = { ProjectRef: 'abcdefghijklmnopqrst', PublishableKey: 'sb_publishable_synthetic_example_key', ConnectionCheck: 'capture-audio-diagnostics-v1' };
  const build = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', settings).targets;
  assert.equal(build.PhrabitCapture.info.properties.PhrabitDiagnosticsOnly, true);
  assert.equal(build.PhrabitCaptureControl.info.properties.PhrabitDiagnosticsOnly, true);
  assert.equal(build.PhrabitCaptureControl.info.properties.PhrabitPreviewAuthOnly, undefined);
  assert.equal(build.PhrabitCapture.info.properties.NSMicrophoneUsageDescription, 'この接続検証版はマイクを使用しません。');
  assert.deepEqual(build.PhrabitCapture.info.properties.PhrabitPreviewAuthOnly, settings);
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', { ...settings, LocalMockRecording: 'true' }), /cannot include recording/);
  assert.equal(distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1').targets.PhrabitCaptureControl.info.properties.PhrabitDiagnosticsOnly, undefined);
});

test('only the application gets auth configuration and a no-microphone description', () => {
  const settings = { ProjectRef: 'abcdefghijklmnopqrst', PublishableKey: 'sb_publishable_synthetic_example_key' };
  const spec = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', settings);
  assert.deepEqual(spec.targets.PhrabitCapture.info.properties.PhrabitPreviewAuthOnly, settings);
  assert.match(spec.targets.PhrabitCapture.info.properties.NSMicrophoneUsageDescription, /使用しません/);
  assert.equal(spec.targets.PhrabitCaptureControl.info.properties.PhrabitPreviewAuthOnly, undefined);
  assert.equal(distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1').targets.PhrabitCapture.info.properties.PhrabitPreviewAuthOnly, undefined);
  const captureSettings = { ...settings, ConnectionCheck: 'capture-edge-v1' };
  const captureSpec = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', captureSettings);
  assert.deepEqual(captureSpec.targets.PhrabitCapture.info.properties.PhrabitPreviewAuthOnly, captureSettings);
  assert.equal(captureSpec.targets.PhrabitCaptureControl.info.properties.PhrabitPreviewAuthOnly, undefined);
});

test('auth-only manifest declares linked account fields, not tracking or audio', () => {
  const categories = previewAuthPrivacyCategories();
  assert.deepEqual(categories.map(value => value.NSPrivacyCollectedDataType),
    ['NSPrivacyCollectedDataTypeName', 'NSPrivacyCollectedDataTypeEmailAddress', 'NSPrivacyCollectedDataTypeUserID']);
  assert.ok(categories.every(value => value.NSPrivacyCollectedDataTypeLinked && !value.NSPrivacyCollectedDataTypeTracking &&
    value.NSPrivacyCollectedDataTypePurposes.join() === 'NSPrivacyCollectedDataTypePurposeAppFunctionality'));
});
