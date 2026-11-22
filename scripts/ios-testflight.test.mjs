import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { approvedPreviewProjectDigest, assertTestFlightUploadAllowed, audioPilotMode, classifyCommandFailure, dependencyRevisions, distributionSpec, guestUnsignedSpec, inspectEncryptionEvidence, offlineInternalVariant, previewAuthPrivacyCategories, previewAuthSettings, targetSettingsArguments, validateExecution } from './ios-testflight.mjs';

const approved = { GITHUB_ACTIONS: 'true', GITHUB_REPOSITORY: 'renponpon/phrabit-ios-prototype', GITHUB_REF: 'refs/heads/main', EXPECTED_COMMIT: 'a'.repeat(40), GITHUB_SHA: 'a'.repeat(40), RUNNER_TEMP: '/tmp/runner' };
const appUuid = '11111111-1111-1111-1111-111111111111';
const controlUuid = '22222222-2222-2222-2222-222222222222';
const archivePilot = { IOS_AUDIO_PILOT_ACTION: 'archive', IOS_AUDIO_PILOT_VARIANT: 'translation-home' };
const readyPilotUpload = { IOS_AUDIO_PILOT_ACTION: 'internal-upload', IOS_AUDIO_PILOT_VARIANT: 'translation-home', IOS_AUDIO_PILOT_NO_AUTO_DISTRIBUTION: 'true' };

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

test('audio pilot archive is opt-in, requires isolated Preview auth and excludes older modes', () => {
  const flag = archivePilot;
  assert.throws(() => previewAuthSettings(flag), /requires Preview auth-only mode/);
  assert.throws(() => previewAuthSettings({ IOS_AUDIO_PILOT_ACTION: 'yes' }), /Invalid audio pilot action/);
  for (const other of ['IOS_PREVIEW_CAPTURE_CHECK', 'IOS_PREVIEW_MOCK_RECORDING', 'IOS_PREVIEW_AUDIO_ACCESS_ONLY']) {
    assert.throws(() => previewAuthSettings({ ...flag, IOS_PREVIEW_AUTH_ONLY: 'true', [other]: 'true' }), /excludes other capture modes/);
  }
  assert.throws(() => previewAuthSettings({ ...flag, IOS_PREVIEW_AUTH_ONLY: 'true', IOS_PREVIEW_PROJECT_REF: 'abcdefghijklmnopqrst' }), /Approved isolated Preview project only/);
});

test('signed audio pilot uses an app-target Release flag and describes when voice is shared', () => {
  const settings = { ProjectRef: 'abcdefghijklmnopqrst', PublishableKey: 'sb_publishable_synthetic_example_key', ConnectionCheck: 'capture-audio-pilot-v1' };
  const template = distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', settings, 'none', 'legacy');
  const app = template.targets.PhrabitCapture;
  const control = template.targets.PhrabitCaptureControl;
  assert.deepEqual(app.info.properties.PhrabitPreviewAuthOnly, settings);
  assert.match(app.info.properties.NSMicrophoneUsageDescription, /停止して翻訳.*録音をOpenAI.*認識した文章をGoogle Gemini/);
  assert.deepEqual(app.settings.configs, { Release: { SWIFT_ACTIVE_COMPILATION_CONDITIONS: '$(inherited) PHRABIT_LOCAL_LIVE_AUDIO' } });
  assert.equal(template.settings.configs, undefined);
  assert.equal(control.settings.configs, undefined);
  assert.equal(control.info.properties.PhrabitPreviewAuthOnly, undefined);
  assert.equal(app.info.properties.PhrabitPreviewTranslationHome, undefined);
  assert.equal(app.info.properties.ITSAppUsesNonExemptEncryption, undefined);
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '1.1', { ...settings, LocalMockRecording: 'true' }, 'none', 'legacy'), /excludes local mock/);
});

test('signed translation home pilot adds flags and marker only to the app and rejects other build types', () => {
  const settings = { ProjectRef: 'abcdefghijklmnopqrst', PublishableKey: 'sb_publishable_synthetic_example_key', ConnectionCheck: 'capture-audio-pilot-v1' };
  const template = distributionSpec('TESTTEAM01', appUuid, controlUuid, '16.1', settings, 'none', 'translation-home');
  const { PhrabitCapture: app, PhrabitCaptureControl: control } = template.targets;
  assert.equal(app.settings.configs.Release.SWIFT_ACTIVE_COMPILATION_CONDITIONS, '$(inherited) PHRABIT_LOCAL_LIVE_AUDIO PHRABIT_PREVIEW_TRANSLATION_HOME');
  assert.deepEqual(app.info.properties.PhrabitPreviewAuthOnly, settings);
  assert.equal(app.info.properties.PhrabitPreviewTranslationHome, true);
  assert.equal(app.info.properties.PhrabitOfflineTranslationHome, undefined);
  assert.equal(control.settings.configs, undefined);
  assert.equal(control.info.properties.PhrabitPreviewTranslationHome, undefined);
  assert.equal(control.info.properties.PhrabitPreviewAuthOnly, undefined);
  assert.equal(app.info.properties.ITSAppUsesNonExemptEncryption, undefined);
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '16.1', settings), /exactly one audio pilot variant/);
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '16.1', undefined, 'none', 'translation-home'), /exactly one audio pilot variant/);
  assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '16.1', settings, 'translation-home', 'translation-home'), /cannot embed a Preview configuration/);
});

test('audio pilot draft includes retained text and usage metadata for functionality, without tracking', () => {
  const settings = { ConnectionCheck: 'capture-audio-pilot-v1' };
  const categories = previewAuthPrivacyCategories(settings);
  assert.deepEqual(categories.slice(0, 3), previewAuthPrivacyCategories());
  assert.deepEqual(categories.slice(3).map(value => value.NSPrivacyCollectedDataType),
    ['NSPrivacyCollectedDataTypeOtherUserContent', 'NSPrivacyCollectedDataTypeProductInteraction']);
  assert.ok(categories.every(value => value.NSPrivacyCollectedDataTypeLinked && !value.NSPrivacyCollectedDataTypeTracking &&
    value.NSPrivacyCollectedDataTypePurposes.join() === 'NSPrivacyCollectedDataTypePurposeAppFunctionality'));
});

test('the runner skips Apple upload and script denies it before reading credentials', () => {
  const workflow = readFileSync(new URL('../.github/workflows/ios-testflight.yml', import.meta.url), 'utf8');
  assert.match(workflow, /name: Upload to App Store Connect for internal testing\s+if: \$\{\{ inputs\.audio_pilot_action == 'none' && inputs\.audio_pilot_variant == 'none' && inputs\.offline_internal_variant == 'none' \}\}/);
  assert.match(workflow, /name: Submit audio pilot build to Apple for internal testing only\s+if: \$\{\{ inputs\.audio_pilot_action == 'internal-upload' && inputs\.confirm_audio_pilot_no_auto_distribution && inputs\.offline_internal_variant == 'none' \}\}/);
  assert.doesNotMatch(workflow, /upload-artifact|actions\/cache/);
  for (const unapproved of ['archive', 'internal-upload', undefined, false]) {
    assert.throws(() => assertTestFlightUploadAllowed({ audioPilotMode: unapproved, audioPilotVariant: 'none' }, 'none'), /Ordinary upload cannot submit/);
  }
  assert.doesNotThrow(() => assertTestFlightUploadAllowed({ audioPilotMode: null, audioPilotVariant: 'none' }, 'none'));
});

test('direct upload command rejects a pilot even without access to its package or Apple credentials', () => {
  const runner = mkdtempSync(path.join(tmpdir(), 'phrabit-pilot-upload-test-'));
  const privateDirectory = path.join(runner, 'phrabit-testflight');
  const statePath = path.join(privateDirectory, 'state.json');
  try {
    mkdirSync(privateDirectory);
    const script = fileURLToPath(new URL('./ios-testflight.mjs', import.meta.url));
    const inspected = { audioPilotMode: 'internal-upload', audioPilotVariant: 'translation-home', previewAuthOnly: true, audioPilotInspectionPassed: 'translation-home' };
    for (const [stage, env, state, message] of [
      ['upload', {}, inspected, /Ordinary upload cannot submit/],
      ['upload-audio-pilot', readyPilotUpload, { ...inspected, audioPilotMode: 'archive' }, /Explicit internal audio pilot upload mode required/],
      ['upload-audio-pilot', { ...readyPilotUpload, IOS_AUDIO_PILOT_VARIANT: 'legacy' }, inspected, /exact variant selected for signing/],
      ['upload-audio-pilot', archivePilot, inspected, /Explicit internal audio pilot upload action required/],
      ['upload-audio-pilot', { ...readyPilotUpload, IOS_AUDIO_PILOT_NO_AUTO_DISTRIBUTION: 'false' }, inspected, /automatic distribution check/]
    ]) {
      writeFileSync(statePath, JSON.stringify(state));
      const result = spawnSync(process.execPath, [script, stage], {
        env: { ...approved, ...env, RUNNER_TEMP: runner }, encoding: 'utf8', timeout: 5_000,
      });
      assert.equal(result.status, 1);
      assert.match(result.stderr, message);
    }
  } finally {
    unlinkSync(statePath);
    rmdirSync(privateDirectory);
    rmdirSync(runner);
  }
});

test('offline variants are opt-in and reject online modes and settings', () => {
  assert.equal(offlineInternalVariant({}), 'none');
  for (const invalid of ['yes', '', 'translation-home,startup-timing']) {
    assert.throws(() => offlineInternalVariant({ IOS_OFFLINE_INTERNAL_VARIANT: invalid }), /Invalid offline internal variant/);
  }
  for (const variant of ['startup-timing', 'translation-home', 'guest-home']) {
    const selected = { IOS_OFFLINE_INTERNAL_VARIANT: variant, IOS_GUEST_NO_AUTO_DISTRIBUTION: String(variant === 'guest-home') };
    assert.equal(offlineInternalVariant(selected), variant);
    for (const conflict of ['IOS_PREVIEW_AUTH_ONLY', 'IOS_PREVIEW_CAPTURE_CHECK', 'IOS_PREVIEW_MOCK_RECORDING', 'IOS_PREVIEW_AUDIO_ACCESS_ONLY']) {
      assert.throws(() => offlineInternalVariant({ ...selected, [conflict]: 'true' }), /exclude Preview modes/);
    }
    assert.throws(() => offlineInternalVariant({ ...selected, ...archivePilot }), /exclude an audio pilot/);
    assert.throws(() => offlineInternalVariant({ ...selected, ...readyPilotUpload }), /exclude an audio pilot/);
    for (const setting of ['IOS_PREVIEW_PROJECT_REF', 'IOS_PREVIEW_PUBLISHABLE_KEY']) {
      assert.throws(() => offlineInternalVariant({ ...selected, [setting]: 'synthetic' }), /must not receive Preview settings/);
    }
  }
});

test('guest upload requires its own confirmation and uses the same Release settings as the unsigned build', () => {
  assert.throws(() => offlineInternalVariant({ IOS_OFFLINE_INTERNAL_VARIANT: 'guest-home' }), /own automatic distribution check/);
  assert.throws(() => offlineInternalVariant({ IOS_OFFLINE_INTERNAL_VARIANT: 'translation-home', IOS_GUEST_NO_AUTO_DISTRIBUTION: 'true' }), /own automatic distribution check/);
  const unsigned = guestUnsignedSpec();
  const signed = distributionSpec('TESTTEAM01', appUuid, controlUuid, '17.1', undefined, 'guest-home');
  assert.equal(Object.hasOwn(unsigned, 'settings'), false);
  for (const [name, target] of Object.entries(unsigned.targets)) {
    assert.deepEqual(target.settings, { configs: signed.targets[name].settings.configs });
    assert.deepEqual(target.info, signed.targets[name].info);
  }
  assert.deepEqual(signed.targets.PhrabitCapture.info.properties['CFBundleURLTypes:REPLACE'], []);
  assert.equal(distributionSpec('TESTTEAM01', appUuid, controlUuid, '17.1').targets.PhrabitCapture.info.properties['CFBundleURLTypes:REPLACE'], undefined);
});

test('each offline variant signs both targets without the other variant or a compliance answer', () => {
  const guestMarker = 'PhrabitOfflineGuestTestFlight';
  const variants = [
    ['startup-timing', 'PHRABIT_OFFLINE_STARTUP_TIMING', 'PhrabitOfflineStartupTiming'],
    ['translation-home', 'PHRABIT_OFFLINE_TRANSLATION_HOME', 'PhrabitOfflineTranslationHome'],
    ['guest-home', 'PHRABIT_OFFLINE_GUEST_TESTFLIGHT', guestMarker]
  ];
  for (const [variant, flag, marker] of variants) {
    const build = distributionSpec('TESTTEAM01', appUuid, controlUuid, '14.1', undefined, variant);
    for (const target of Object.values(build.targets)) {
      assert.equal(target.settings.configs.Release.SWIFT_ACTIVE_COMPILATION_CONDITIONS, `$(inherited) ${flag}`);
      assert.equal(target.info.properties[marker], true);
      for (const property of ['PhrabitOfflineTranslationHome', 'PhrabitOfflineStartupTiming', guestMarker, 'PhrabitPreviewAuthOnly', 'PhrabitDiagnosticsOnly', 'ITSAppUsesNonExemptEncryption', 'ITSEncryptionExportComplianceCode'].filter(property => property !== marker)) {
        assert.equal(Object.hasOwn(target.info.properties, property), false);
      }
    }
    assert.match(build.targets.PhrabitCapture.info.properties.NSMicrophoneUsageDescription, /音声は端末外へ送信せず/);
    assert.throws(() => distributionSpec('TESTTEAM01', appUuid, controlUuid, '14.1', {}, variant), /cannot embed a Preview configuration/);
  }
  const usual = distributionSpec('TESTTEAM01', appUuid, controlUuid, '14.1');
  assert.equal(usual.targets.PhrabitCapture.info.properties.PhrabitOfflineStartupTiming, undefined);
  assert.equal(usual.targets.PhrabitCapture.info.properties.PhrabitOfflineTranslationHome, undefined);
  assert.equal(usual.targets.PhrabitCapture.info.properties[guestMarker], undefined);
  assert.equal(usual.targets.PhrabitCaptureControl.settings.configs, undefined);
});

test('offline submissions require the inspected exact variant and are isolated from normal and pilot upload', () => {
  for (const [variant, otherVariant] of [['startup-timing', 'translation-home'], ['translation-home', 'guest-home'], ['guest-home', 'startup-timing']]) {
    const valid = { audioPilotMode: null, audioPilotVariant: 'none', offlineInternalVariant: variant, previewAuthOnly: false, offlineInspectionPassed: true };
    assert.doesNotThrow(() => assertTestFlightUploadAllowed(valid, 'none', variant));
    assert.throws(() => assertTestFlightUploadAllowed(valid, 'none'), /separate internal upload stage/);
    assert.throws(() => assertTestFlightUploadAllowed(valid, 'legacy'), /separate internal upload stage/);
    assert.throws(() => assertTestFlightUploadAllowed(valid, 'translation-home', variant), /modes are exclusive/);
    assert.throws(() => assertTestFlightUploadAllowed(valid, 'none', otherVariant), /exact variant match/);
    for (const override of [{ offlineInspectionPassed: false }, { offlineInternalVariant: 'none' }, { previewAuthOnly: true }, { audioPilotMode: 'internal-upload' }]) {
      assert.throws(() => assertTestFlightUploadAllowed({ ...valid, ...override }, 'none', variant), /completed offline binary check/);
    }
  }
  const workflow = readFileSync(new URL('../.github/workflows/ios-testflight.yml', import.meta.url), 'utf8');
  assert.match(workflow, /offline_internal_variant:\s+description:[^\r\n]+\s+type: choice\s+required: false\s+default: 'none'\s+options:\s+- 'none'\s+- startup-timing\s+- translation-home\s+- guest-home/);
  assert.match(workflow, /confirm_guest_no_auto_distribution:\s+description:[^\r\n]+\s+type: boolean\s+required: false\s+default: false/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main' && inputs\.confirm_internal_only && inputs\.confirm_guest_no_auto_distribution == \(inputs\.offline_internal_variant == 'guest-home'\)/);
  assert.match(workflow, /name: Submit the inspected offline build for internal testing only\s+if: \$\{\{ inputs\.offline_internal_variant == 'startup-timing' \|\| inputs\.offline_internal_variant == 'translation-home' \|\| \(inputs\.offline_internal_variant == 'guest-home' && inputs\.confirm_guest_no_auto_distribution\) \}\}\s+env:\s+IOS_OFFLINE_INTERNAL_VARIANT:[^\r\n]+\s+IOS_GUEST_NO_AUTO_DISTRIBUTION:[^\r\n]+[\s\S]*?run: node scripts\/ios-testflight\.mjs upload-offline/);
  for (const setting of ['IOS_PREVIEW_PROJECT_REF', 'IOS_PREVIEW_PUBLISHABLE_KEY']) {
    assert.ok(workflow.includes(`${setting}: \${{ inputs.offline_internal_variant == 'none' && secrets.${setting} || '' }}`));
  }
});

test('direct offline upload rejects an omitted or mismatched variant before reading Apple credentials', () => {
  const runner = mkdtempSync(path.join(tmpdir(), 'phrabit-offline-upload-test-'));
  const privateDirectory = path.join(runner, 'phrabit-testflight');
  const statePath = path.join(privateDirectory, 'state.json');
  try {
    mkdirSync(privateDirectory);
    writeFileSync(statePath, JSON.stringify({
      audioPilotMode: null, audioPilotVariant: 'none', offlineInternalVariant: 'translation-home', previewAuthOnly: false, offlineInspectionPassed: true,
    }));
    const script = fileURLToPath(new URL('./ios-testflight.mjs', import.meta.url));
    for (const [settings, message] of [
      [{}, /Explicit offline variant required/],
      [{ IOS_OFFLINE_INTERNAL_VARIANT: 'startup-timing' }, /exact variant match/],
      [{ IOS_OFFLINE_INTERNAL_VARIANT: 'guest-home' }, /own automatic distribution check/],
    ]) {
      const result = spawnSync(process.execPath, [script, 'upload-offline'], {
        env: { ...approved, ...settings, RUNNER_TEMP: runner }, encoding: 'utf8', timeout: 5_000,
      });
      assert.equal(result.status, 1);
      assert.match(result.stderr, message);
    }
  } finally {
    unlinkSync(statePath);
    rmdirSync(privateDirectory);
    rmdirSync(runner);
  }
});

test('pilot upload is distinct from archive-only and requires an independent group check', () => {
  const groupCheck = { IOS_AUDIO_PILOT_NO_AUTO_DISTRIBUTION: 'true' };
  assert.equal(audioPilotMode({}), null);
  assert.equal(audioPilotMode(archivePilot), 'archive');
  assert.equal(audioPilotMode(readyPilotUpload), 'internal-upload');
  assert.throws(() => audioPilotMode({ ...readyPilotUpload, IOS_AUDIO_PILOT_NO_AUTO_DISTRIBUTION: 'false' }), /automatic distribution check/);
  assert.throws(() => audioPilotMode(groupCheck), /automatic distribution check/);
  assert.throws(() => audioPilotMode({ ...archivePilot, ...groupCheck }), /automatic distribution check/);
  assert.throws(() => audioPilotMode({ IOS_AUDIO_PILOT_ACTION: 'archive' }), /exactly one audio pilot variant/);
  assert.throws(() => audioPilotMode({ IOS_AUDIO_PILOT_VARIANT: 'translation-home' }), /exactly one audio pilot variant/);
  assert.throws(() => audioPilotMode({ ...archivePilot, IOS_AUDIO_PILOT_VARIANT: 'legacy,translation-home' }), /exactly one audio pilot variant/);
  assert.throws(() => previewAuthSettings(readyPilotUpload), /requires Preview auth-only mode/);
});

test('pilot submission requires a completed binary check on the exact pilot build mode', () => {
  for (const [variant, other] of [['legacy', 'translation-home'], ['translation-home', 'legacy']]) {
    const validated = { audioPilotMode: 'internal-upload', audioPilotVariant: variant, previewAuthOnly: true, audioPilotInspectionPassed: variant };
    assert.doesNotThrow(() => assertTestFlightUploadAllowed(validated, variant));
    assert.throws(() => assertTestFlightUploadAllowed(validated, other), /exact variant selected for signing/);
    assert.throws(() => assertTestFlightUploadAllowed({ ...validated, audioPilotMode: 'archive' }, variant), /Explicit internal/);
    assert.throws(() => assertTestFlightUploadAllowed({ ...validated, audioPilotInspectionPassed: other }, variant), /completed binary check/);
    assert.throws(() => assertTestFlightUploadAllowed({ ...validated, previewAuthOnly: false }, variant), /isolated Preview/);
  }
});

test('binary inspection accepts Apple platform links and identifies encryption evidence without asserting exemption', () => {
  const libraryList = (...names) => 'PhrabitCapture:\n' + names.map(name => `\t${name} (compatibility version 1.0.0, current version 1.0.0)`).join('\n');
  const crypto = '/System/Library/Frameworks/CryptoKit.framework/CryptoKit';
  const swift = '@rpath/libswift_Concurrency.dylib';
  assert.equal(inspectEncryptionEvidence(libraryList(crypto, swift, '/usr/lib/libSystem.B.dylib'), '                 (undefined) external _SecItemCopyMatching'), true);
  assert.equal(inspectEncryptionEvidence(libraryList(swift), ''), false);
  assert.throws(() => inspectEncryptionEvidence('Malformed output', ''), /Unable to identify linked libraries/);
  assert.throws(() => inspectEncryptionEvidence(libraryList(crypto, '@rpath/Unknown.framework/Unknown'), ''), /unreviewed embedded library/);
  for (const symbol of ['_CCryptoBoringSSL_EVP_PKEY_new', '                  (undefined) external _SSL_new', '00000001501 t _$s5CXKCPFunction']) {
    assert.throws(() => inspectEncryptionEvidence(libraryList(crypto), symbol), /Third-party cryptography indicators/);
  }
});

test('dependency evidence detects revision changes and rejects missing pins', () => {
  const pinned = { identity: 'synthetic-crypto', state: { revision: 'a'.repeat(40), version: '1.2.3' } };
  const serialize = (...pins) => JSON.stringify({ pins });
  assert.deepEqual(dependencyRevisions(serialize(pinned)), [['synthetic-crypto', 'a'.repeat(40), '1.2.3']]);
  assert.notDeepEqual(dependencyRevisions(serialize({ ...pinned, state: { ...pinned.state, revision: 'b'.repeat(40) } })),
    dependencyRevisions(serialize(pinned)));
  assert.throws(() => dependencyRevisions(serialize()), /Missing locked dependency revisions/);
});
