import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const approvedPreviewProjectDigest = '34f9aba9cefba7372e95560573ca702cb13e4ad0b3aed770d52e3096ec8334f5';
const audioPilotContract = 'capture-audio-pilot-v1';
const audioPilotFlag = 'PHRABIT_LOCAL_LIVE_AUDIO';
const translationHomePilotFlag = 'PHRABIT_PREVIEW_TRANSLATION_HOME';
const translationHomePilotMarker = 'PhrabitPreviewTranslationHome';
const audioPilotMicrophoneDescription = '本人限定の音声翻訳テストに使います。「停止して翻訳」を押したときだけ録音をOpenAIへ、認識した文章をGoogle Geminiへ送信します。';
const offlineGuestVariant = 'guest-home';
const connectionVariant = 'guest-connection';
const connectionTarget = 'PhrabitGuestConnection';
const connectionMarker = 'PhrabitGuestConnectionOnly';
const deviceVariant = 'guest-device-probe';
const deviceTarget = 'PhrabitGuestDeviceProbe';
const deviceMarker = 'PhrabitGuestDeviceProofOnly';
const attestEntitlement = 'com.apple.developer.devicecheck.appattest-environment';
const standaloneBuilds = new Map([
  [connectionVariant, { target: connectionTarget, marker: connectionMarker, spec: 'guest-connection.yml', inspection: 'connectionInspectionPassed' }],
  [deviceVariant, { target: deviceTarget, marker: deviceMarker, spec: 'guest-device-probe.yml', inspection: 'deviceProbeInspectionPassed' }]
]);
const offlineBuilds = new Map([
  ['startup-timing', {
    flag: 'PHRABIT_OFFLINE_STARTUP_TIMING',
    marker: 'PhrabitOfflineStartupTiming',
    microphone: 'ロック画面から録音開始までの時間を計ります。音声は端末外へ送信せず、試行後に削除します。'
  }],
  ['translation-home', {
    flag: 'PHRABIT_OFFLINE_TRANSLATION_HOME',
    marker: 'PhrabitOfflineTranslationHome',
    microphone: '翻訳画面で録音を試します。音声は端末外へ送信せず、録音の終了後に削除します。'
  }],
  [offlineGuestVariant, {
    flag: 'PHRABIT_OFFLINE_GUEST_TESTFLIGHT',
    marker: 'PhrabitOfflineGuestTestFlight',
    microphone: 'ログインなしの試作で録音を確認します。音声は端末外へ送信せず、録音の終了後に削除します。'
  }]
]);

function offlineBuild(variant) {
  if (variant === 'none') return undefined;
  assert.ok(offlineBuilds.has(variant), 'Invalid offline internal variant');
  return offlineBuilds.get(variant);
}

export function validateExecution(environment) {
  assert.equal(environment.GITHUB_ACTIONS, 'true', 'GitHub Actions is required');
  assert.equal(environment.GITHUB_REPOSITORY, 'renponpon/phrabit-ios-prototype', 'Dedicated prototype repository only');
  assert.equal(environment.GITHUB_REF, 'refs/heads/main', 'Only main may distribute');
  assert.match(environment.EXPECTED_COMMIT ?? '', /^[a-f0-9]{40}$/, 'A full approved commit is required');
  assert.equal(environment.GITHUB_SHA, environment.EXPECTED_COMMIT, 'Approved commit mismatch');
  assert.ok(environment.RUNNER_TEMP, 'Ephemeral runner storage is required');
}

export function audioPilotMode(environment) {
  const action = environment.IOS_AUDIO_PILOT_ACTION ?? 'none';
  const variant = environment.IOS_AUDIO_PILOT_VARIANT ?? 'none';
  const noAutoDistribution = environment.IOS_AUDIO_PILOT_NO_AUTO_DISTRIBUTION ?? 'false';
  assert.ok(['none', 'archive', 'internal-upload'].includes(action), 'Invalid audio pilot action');
  assert.equal(noAutoDistribution, String(action === 'internal-upload'), 'Internal pilot upload requires a separate automatic distribution check');
  assertAudioPilotVariant(variant, action !== 'none');
  return action === 'none' ? null : action;
}

function assertAudioPilotVariant(variant, active) {
  assert.ok(active ? ['legacy', 'translation-home'].includes(variant) : variant === 'none', 'Select exactly one audio pilot variant with an audio pilot action');
}

export function offlineInternalVariant(environment) {
  const variant = environment.IOS_OFFLINE_INTERNAL_VARIANT ?? 'none';
  assert.equal(environment.IOS_GUEST_NO_AUTO_DISTRIBUTION ?? 'false', String(variant === offlineGuestVariant || standaloneBuilds.has(variant)), 'Guest TestFlight requires its own automatic distribution check');
  if (!standaloneBuilds.has(variant) && !offlineBuild(variant)) return variant;
  for (const other of ['IOS_PREVIEW_AUTH_ONLY', 'IOS_PREVIEW_CAPTURE_CHECK', 'IOS_PREVIEW_MOCK_RECORDING', 'IOS_PREVIEW_AUDIO_ACCESS_ONLY']) {
    assert.equal(environment[other] ?? 'false', 'false', 'Offline internal builds exclude Preview modes');
  }
  assert.equal(audioPilotMode(environment), null, 'Offline internal builds exclude an audio pilot');
  assert.ok(!environment.IOS_PREVIEW_PROJECT_REF && !environment.IOS_PREVIEW_PUBLISHABLE_KEY, 'Offline internal builds must not receive Preview settings');
  return variant;
}

export function previewAuthSettings(environment) {
  const captureCheck = environment.IOS_PREVIEW_CAPTURE_CHECK ?? 'false';
  const mockRecording = environment.IOS_PREVIEW_MOCK_RECORDING ?? 'false';
  const audioAccessOnly = environment.IOS_PREVIEW_AUDIO_ACCESS_ONLY ?? 'false';
  const pilotMode = audioPilotMode(environment);
  assert.ok(captureCheck === 'false' || captureCheck === 'true', 'Invalid capture check mode');
  assert.ok(mockRecording === 'false' || mockRecording === 'true', 'Invalid mock recording mode');
  assert.ok(audioAccessOnly === 'false' || audioAccessOnly === 'true', 'Invalid audio diagnostics mode');
  if (pilotMode) {
    assert.equal(environment.IOS_PREVIEW_AUTH_ONLY, 'true', 'Audio pilot requires Preview auth-only mode');
    assert.ok(captureCheck === 'false' && mockRecording === 'false' && audioAccessOnly === 'false', 'Audio pilot excludes other capture modes');
  }
  if (audioAccessOnly === 'true') {
    assert.equal(environment.IOS_PREVIEW_AUTH_ONLY, 'true', 'Audio diagnostics requires Preview auth-only mode');
    assert.ok(captureCheck === 'false' && mockRecording === 'false', 'Audio diagnostics cannot include legacy diagnostics or recording');
  }
  if (mockRecording === 'true') assert.equal(captureCheck, 'true', 'Local mock recording requires Preview capture check');
  if (captureCheck === 'true') assert.equal(environment.IOS_PREVIEW_AUTH_ONLY, 'true', 'Capture check requires Preview auth-only mode');
  if (!environment.IOS_PREVIEW_AUTH_ONLY || environment.IOS_PREVIEW_AUTH_ONLY === 'false') return undefined;
  assert.equal(environment.IOS_PREVIEW_AUTH_ONLY, 'true', 'Invalid preview mode');
  const reference = environment.IOS_PREVIEW_PROJECT_REF ?? '';
  const publishableKey = environment.IOS_PREVIEW_PUBLISHABLE_KEY ?? '';
  assert.ok(/^[a-z]{20}$/.test(reference) && createHash('sha256').update(reference).digest('hex') === approvedPreviewProjectDigest, 'Approved isolated Preview project only');
  assert.ok(/^sb_publishable_[A-Za-z0-9_-]{20,150}$/.test(publishableKey), 'A modern publishable key is required; secret and service-role keys are not accepted');
  return { ProjectRef: reference, PublishableKey: publishableKey,
    ...(captureCheck === 'true' ? { ConnectionCheck: 'capture-edge-v1' } : {}),
    ...(audioAccessOnly === 'true' ? { ConnectionCheck: 'capture-audio-diagnostics-v1' } : {}),
    ...(pilotMode ? { ConnectionCheck: audioPilotContract } : {}),
    ...(mockRecording === 'true' ? { LocalMockRecording: 'true' } : {}) };
}

export function previewAuthPrivacyCategories(settings) {
  const categories = ['Name', 'EmailAddress', 'UserID'];
  if (settings?.ConnectionCheck === audioPilotContract) categories.push('OtherUserContent', 'ProductInteraction');
  return categories.map(category => ({
    NSPrivacyCollectedDataType: `NSPrivacyCollectedDataType${category}`,
    NSPrivacyCollectedDataTypeLinked: true,
    NSPrivacyCollectedDataTypeTracking: false,
    NSPrivacyCollectedDataTypePurposes: ['NSPrivacyCollectedDataTypePurposeAppFunctionality']
  }));
}

export function assertTestFlightUploadAllowed(state, requestedPilotVariant, requestedOfflineVariant = 'none') {
  const pilotSubmission = requestedPilotVariant !== 'none';
  assertAudioPilotVariant(requestedPilotVariant, pilotSubmission);
  const standalone = standaloneBuilds.get(requestedOfflineVariant);
  if (standalone || offlineBuild(requestedOfflineVariant)) {
    assert.ok(!pilotSubmission, 'Upload modes are exclusive');
    assert.ok(state.offlineInternalVariant === requestedOfflineVariant && state.previewAuthOnly === false &&
      state.audioPilotMode === null && state.audioPilotVariant === 'none' && state.offlineInspectionPassed === true, 'Offline upload requires an exact variant match and a completed offline binary check');
    if (standalone) assert.equal(state[standalone.inspection], true, 'Upload requires the standalone signed app inspection');
    return;
  }
  assert.equal(state.offlineInternalVariant ?? 'none', 'none', 'Offline builds require their separate internal upload stage');
  if (!pilotSubmission) {
    assert.ok(state.audioPilotMode === null && state.audioPilotVariant === 'none', 'Ordinary upload cannot submit an audio pilot');
    return;
  }
  assert.equal(state.audioPilotMode, 'internal-upload', 'Explicit internal audio pilot upload mode required');
  assert.equal(state.audioPilotVariant, requestedPilotVariant, 'Audio pilot upload requires the exact variant selected for signing');
  assert.ok(state.previewAuthOnly === true && state.audioPilotInspectionPassed === requestedPilotVariant, 'Audio pilot requires isolated Preview and a completed binary check for that variant');
}

export function inspectEncryptionEvidence(linkedLibraries, symbols) {
  const libraries = [...linkedLibraries.matchAll(/^\s+([^\r\n]+?)\s+\(compatibility version /gm)].map(match => match[1]);
  assert.ok(libraries.length > 0, 'Unable to identify linked libraries in the signed executable');
  const osLibrary = /^(?:\/System\/Library\/|\/usr\/lib\/|@rpath\/libswift[\w+.-]*\.dylib$)/;
  assert.ok(libraries.every(library => osLibrary.test(library)), 'An unreviewed embedded library requires encryption review');
  const knownThirdParty = /BoringSSL|CryptoBoringWrapper|CXKCP|\/lib(?:crypto|ssl|sodium|mbedtls)[.\d]|\b_(?:SSL_new|EVP_EncryptInit_ex|sodium_init)\b/i;
  assert.ok(!knownThirdParty.test(libraries.join('\n') + '\n' + symbols), 'Third-party cryptography indicators require manual review');
  return libraries.some(library => /\/(?:CryptoKit|Security)\.framework\//.test(library));
}

export function dependencyRevisions(contents) {
  const { pins } = JSON.parse(contents);
  assert.ok(Array.isArray(pins) && pins.length > 0, 'Missing locked dependency revisions');
  return pins.map(pin => {
    assert.match(pin.identity ?? '', /^[\w.-]+$/);
    assert.match(pin.state?.revision ?? '', /^[a-f0-9]{40}$/);
    return [pin.identity, pin.state.revision, pin.state.version];
  }).sort(([left], [right]) => left.localeCompare(right));
}

export function distributionSpec(teamId, appUuid, controlUuid, buildNumber, previewSettings, offlineVariant = 'none', pilotVariant = 'none') {
  assert.match(teamId, /^[A-Z0-9]{10}$/);
  assert.match(appUuid, /^[A-F0-9-]{36}$/i);
  assert.match(controlUuid, /^[A-F0-9-]{36}$/i);
  assert.notEqual(appUuid, controlUuid);
  assert.match(buildNumber, /^[1-9]\d{0,3}\.[1-9]\d{0,3}$/);
  const offline = offlineBuild(offlineVariant);
  assert.ok(!offline || !previewSettings, 'An offline build cannot embed a Preview configuration');
  const signing = {
    DEVELOPMENT_TEAM: teamId,
    CODE_SIGN_STYLE: 'Manual',
    CODE_SIGN_IDENTITY: 'Apple Distribution',
    'CODE_SIGN_IDENTITY[sdk=iphoneos*]': 'Apple Distribution',
    CURRENT_PROJECT_VERSION: buildNumber,
    MARKETING_VERSION: '0.1.0'
  };
  const info = { properties: { CFBundleVersion: '$(CURRENT_PROJECT_VERSION)', CFBundleShortVersionString: '$(MARKETING_VERSION)' } };
  const diagnosticsOnly = previewSettings?.ConnectionCheck === 'capture-audio-diagnostics-v1';
  const audioPilot = previewSettings?.ConnectionCheck === audioPilotContract;
  assertAudioPilotVariant(pilotVariant, audioPilot);
  const translationHomePilot = pilotVariant === 'translation-home';
  const pilotFlags = [audioPilotFlag, ...(translationHomePilot ? [translationHomePilotFlag] : [])].join(' ');
  if (diagnosticsOnly) assert.ok(!('LocalMockRecording' in previewSettings), 'Diagnostics cannot include recording');
  if (audioPilot) assert.ok(!('LocalMockRecording' in previewSettings), 'Audio pilot excludes local mock recording');
  const diagnosticsMarker = diagnosticsOnly ? { PhrabitDiagnosticsOnly: true } : {};
  const offlineMarker = offline ? { [offline.marker]: true } : {};
  const guestProperties = offlineVariant === offlineGuestVariant ? { 'CFBundleURLTypes:REPLACE': [] } : {};
  const offlineConditions = offline ? { configs: { Release: { SWIFT_ACTIVE_COMPILATION_CONDITIONS: `$(inherited) ${offline.flag}` } } } : {};
  return {
    include: ['project.yml'],
    settings: { base: signing },
    targets: {
      PhrabitCapture: {
        settings: {
          base: { ...signing, PROVISIONING_PROFILE_SPECIFIER: appUuid },
          ...offlineConditions,
          ...(audioPilot ? { configs: { Release: { SWIFT_ACTIVE_COMPILATION_CONDITIONS: `$(inherited) ${pilotFlags}` } } } : {})
        },
        info: previewSettings ? { properties: {
          ...info.properties,
          ...diagnosticsMarker,
          ...(translationHomePilot ? { [translationHomePilotMarker]: true } : {}),
          PhrabitPreviewAuthOnly: previewSettings,
          NSMicrophoneUsageDescription: audioPilot ? audioPilotMicrophoneDescription : previewSettings.LocalMockRecording === 'true'
            ? '端末内で録音を試します。音声は送信せず、録音後に削除します。'
            : 'この接続検証版はマイクを使用しません。'
        } } : offline ? { properties: {
          ...info.properties, ...offlineMarker, ...guestProperties, NSMicrophoneUsageDescription: offline.microphone
        } } : info
      },
      PhrabitCaptureControl: { settings: { base: { ...signing, PROVISIONING_PROFILE_SPECIFIER: controlUuid }, ...offlineConditions },
        info: { properties: { ...info.properties, ...diagnosticsMarker, ...offlineMarker } } }
    }
  };
}

export function guestUnsignedSpec() {
  const base = distributionSpec('TESTTEAM01', '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000002', '1.1', undefined, offlineGuestVariant);
  return {
    include: base.include,
    targets: Object.fromEntries(Object.entries(base.targets).map(([name, target]) => [
      name, { settings: { configs: target.settings.configs }, info: target.info }
    ]))
  };
}

export function guestConnectionDistributionSpec(teamId, appUuid, buildNumber) {
  return standaloneDistributionSpec(standaloneBuilds.get(connectionVariant), teamId, appUuid, buildNumber);
}

export function guestDeviceProbeDistributionSpec(teamId, appUuid, buildNumber) {
  return standaloneDistributionSpec(standaloneBuilds.get(deviceVariant), teamId, appUuid, buildNumber);
}

function standaloneDistributionSpec({ target, marker, spec }, teamId, appUuid, buildNumber) {
  assert.match(teamId, /^[A-Z0-9]{10}$/);
  assert.match(appUuid, /^[A-F0-9-]{36}$/i);
  assert.match(buildNumber, /^[1-9]\d{0,3}\.[1-9]\d{0,3}$/);
  return {
    include: [spec],
    targets: {
      [target]: {
        settings: { configs: { Release: {
          CODE_SIGNING_ALLOWED: 'YES',
          CODE_SIGNING_REQUIRED: 'YES',
          CODE_SIGN_STYLE: 'Manual',
          CODE_SIGN_IDENTITY: 'Apple Distribution',
          'CODE_SIGN_IDENTITY[sdk=iphoneos*]': 'Apple Distribution',
          DEVELOPMENT_TEAM: teamId,
          PROVISIONING_PROFILE_SPECIFIER: appUuid,
          CURRENT_PROJECT_VERSION: buildNumber,
          SKIP_INSTALL: 'NO'
        } } },
        info: { properties: {
          [marker]: true,
          CFBundleVersion: '$(CURRENT_PROJECT_VERSION)',
          CFBundleShortVersionString: '$(MARKETING_VERSION)'
        } }
      }
    }
  };
}

export function assertGuestConnectionBundle(info, executable, buildNumber) {
  assertStandaloneBundle(standaloneBuilds.get(connectionVariant), info, executable, buildNumber);
  for (const marker of ['phrabit-ios-guest-preview-', '/api/ios/guest/status']) {
    assert.ok(executable.includes(marker), 'Missing isolated Preview status URL rule');
  }
}

export function assertGuestDeviceProbeBundle(info, executable, entitlements, team, buildNumber) {
  assertStandaloneBundle(standaloneBuilds.get(deviceVariant), info, executable, buildNumber);
  assert.equal(entitlements[attestEntitlement], 'production', 'Missing signed App Attest production entitlement');
  assert.equal(entitlements['application-identifier'], team + '.com.phrabit.app');
  assert.ok(entitlements['get-task-allow'] !== true, 'An internal upload must not permit debugging');
  for (const marker of ['phrabit-ios-guest-preview-', '/api/ios/guest/device-test', '/api/ios/guest/device-check', 'DCAppAttestService']) {
    assert.ok(executable.includes(marker), 'Missing isolated device proof implementation');
  }
  assert.ok(!executable.includes('/api/ios/guest/capture'), 'Unexpected capture route');
}

function assertStandaloneBundle({ target, marker }, info, executable, buildNumber) {
  assert.equal(info.CFBundleIdentifier, 'com.phrabit.app');
  assert.equal(info.CFBundleExecutable, target);
  assert.equal(info.CFBundleVersion, buildNumber);
  assert.equal(info.CFBundleShortVersionString, '0.1.0');
  assert.equal(info[marker], true);
  for (const key of [
    'ITSAppUsesNonExemptEncryption', 'ITSEncryptionExportComplianceCode', 'NSMicrophoneUsageDescription',
    'NSCameraUsageDescription', 'NSSpeechRecognitionUsageDescription', 'CFBundleURLTypes', 'NSAppTransportSecurity',
    'UIBackgroundModes', 'PhrabitPreviewAuthOnly', 'PhrabitDiagnosticsOnly', translationHomePilotMarker,
    ...Array.from(standaloneBuilds.values(), item => item.marker).filter(item => item !== marker),
    ...Array.from(offlineBuilds.values(), ({ marker }) => marker)
  ]) {
    assert.ok(!Object.hasOwn(info, key), `Unexpected connection bundle key: ${key}`);
  }
  for (const marker of ['AVAudioRecorder', 'requestRecordPermission', 'CaptureHTTPProcessor', 'URLSession', 'supabase.co', 'x-phrabit-preview-pass']) {
    assert.ok(!executable.includes(marker), `Unexpected connection executable marker: ${marker}`);
  }
}

export function classifyCommandFailure(output) {
  const appleCode = output.match(/\bITMS-\d{5}\b/);
  if (appleCode) return appleCode[0];
  for (const [pattern, code] of [
    [/User interaction is not allowed|errSecInternalComponent/i, 'KEYCHAIN_ACCESS'],
    [/unable to build chain|CSSMERR_TP_NOT_TRUSTED/i, 'CERTIFICATE_TRUST_CHAIN'],
    [/No signing certificate|No valid signing identities/i, 'SIGNING_IDENTITY'],
    [/Provisioning profile.*(?:does not|doesn't|invalid|expired)/i, 'PROVISIONING_PROFILE'],
    [/private key.*(?:not found|could not)|could not find.*private key/i, 'API_KEY_LOOKUP'],
    [/unknown option|unrecognized argument/i, 'TOOL_ARGUMENT'],
    [/No such file or directory|command not found/i, 'TOOL_OR_FILE_MISSING']
  ]) {
    if (pattern.test(output)) return code;
  }
  return 'PRIVATE_DIAGNOSTICS_SUPPRESSED';
}

export function targetSettingsArguments(target) {
  const standalone = Array.from(standaloneBuilds.values()).find(item => item.target === target);
  assert.ok(standalone || ['PhrabitCapture', 'PhrabitCaptureControl'].includes(target));
  const project = standalone?.target ?? 'PhrabitCapture';
  return ['-project', `${project}.xcodeproj`, '-target', target, '-configuration', 'Release', '-sdk', 'iphoneos', '-showBuildSettings', '-json'];
}

function main(stage) {
  const environment = process.env;
  assert.ok(environment.RUNNER_TEMP, 'Runner temporary directory is required');
  const runnerRoot = path.resolve(environment.RUNNER_TEMP);
  const privateRoot = path.join(runnerRoot, 'phrabit-testflight');
  assert.ok(privateRoot.startsWith(runnerRoot + path.sep));
  const statePath = path.join(privateRoot, 'state.json');
  const keychainPath = path.join(privateRoot, 'signing.keychain-db');
  const prototype = fileURLToPath(new URL('../native/ios/PhrabitCapture/', import.meta.url));
  const readState = () => JSON.parse(readFileSync(statePath, 'utf8'));
  const saveState = (state) => writeFileSync(statePath, JSON.stringify(state), { mode: 0o600 });
  const writePrivate = (filename, contents) => writeFileSync(filename, contents, { mode: 0o600, flag: 'wx' });
  const run = (command, argumentsList, label, options = {}) => {
    const result = spawnSync(command, argumentsList, { cwd: prototype, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 600000, ...options });
    if (existsSync(privateRoot)) writeFileSync(path.join(privateRoot, `${label}.log`), `${result.stdout ?? ''}\n${result.stderr ?? ''}`, { mode: 0o600 });
    assert.equal(result.status, 0, `${label} failed (${classifyCommandFailure(`${result.stdout ?? ''}\n${result.stderr ?? ''}`)}); private command output is not published`);
    return result.stdout;
  };
  const requireSecret = (name) => {
    assert.ok(environment[name], `Missing ${name}`);
    return environment[name];
  };
  const exportArchive = (archivePath) => {
    const exportPath = path.join(privateRoot, 'export');
    run('xcodebuild', ['-exportArchive', '-archivePath', archivePath, '-exportPath', exportPath, '-exportOptionsPlist', path.join(privateRoot, 'ExportOptions.plist')], 'ipa-export');
    const packages = readdirSync(exportPath).filter((filename) => filename.endsWith('.ipa'));
    assert.equal(packages.length, 1);
    return path.join(exportPath, packages[0]);
  };
  const assertInternalExport = (requiresLocalExport) => {
    const help = spawnSync('xcodebuild', ['-help'], { cwd: prototype, encoding: 'utf8' });
    assert.match(`${help.stdout ?? ''}\n${help.stderr ?? ''}`, /\btestFlightInternalTestingOnly\b/);
    const options = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(privateRoot, 'ExportOptions.plist')], 'preview-export-settings'));
    assert.equal(options.testFlightInternalTestingOnly, true, 'The build must be internal only');
    if (requiresLocalExport) assert.equal(options.destination, 'export', 'The archive must be exported locally before any submission');
    return options;
  };

  if (stage === 'cleanup') {
    if (existsSync(statePath)) {
      const state = readState();
      if (state.previousKeychains?.length) spawnSync('security', ['list-keychains', '-d', 'user', '-s', ...state.previousKeychains], { encoding: 'utf8' });
      for (const filename of state.installedProfiles ?? []) {
        const allowedRoots = [path.join(os.homedir(), 'Library/MobileDevice/Provisioning Profiles'), path.join(os.homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles')];
        assert.ok(allowedRoots.some((allowedRoot) => path.resolve(filename).startsWith(allowedRoot + path.sep)));
        rmSync(filename, { force: true });
      }
      if (state.apiKeyPath) {
        assert.equal(path.dirname(state.apiKeyPath), path.join(os.homedir(), '.appstoreconnect/private_keys'));
        assert.match(path.basename(state.apiKeyPath), /^AuthKey_[A-Z0-9]{10}\.p8$/);
        rmSync(state.apiKeyPath, { force: true });
      }
    }
    if (existsSync(keychainPath)) spawnSync('security', ['delete-keychain', keychainPath], { encoding: 'utf8' });
    rmSync(privateRoot, { recursive: true, force: true });
    console.log('Temporary signing credentials, profiles, keychain, logs, and IPA removed.');
    return;
  }

  validateExecution(environment);
  if (stage === 'prepare') {
    const offlineVariant = offlineInternalVariant(environment);
    const standalone = standaloneBuilds.get(offlineVariant);
    const offline = standalone || Boolean(offlineBuild(offlineVariant));
    const previewSettings = previewAuthSettings(environment);
    const pilotMode = audioPilotMode(environment);
    const pilotVariant = environment.IOS_AUDIO_PILOT_VARIANT ?? 'none';
    mkdirSync(privateRoot, { mode: 0o700 });
    const previousKeychains = [...run('security', ['list-keychains', '-d', 'user'], 'keychain-search-list').matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    const state = { previousKeychains, installedProfiles: [] };
    saveState(state);
    const certificatePath = path.join(privateRoot, 'certificate.p12');
    writePrivate(certificatePath, Buffer.from(requireSecret('IOS_SIGNING_CERTIFICATE_BASE64'), 'base64'));
    const profiles = [];
    const requiredProfiles = [['IOS_APP_PROFILE_BASE64', 'com.phrabit.app']];
    if (!standalone) requiredProfiles.push(['IOS_CONTROL_PROFILE_BASE64', 'com.phrabit.app.control']);
    for (const [secretName, bundleId] of requiredProfiles) {
      const profilePath = path.join(privateRoot, `${secretName}.mobileprovision`);
      writePrivate(profilePath, Buffer.from(requireSecret(secretName), 'base64'));
      const xmlPath = path.join(privateRoot, `${secretName}.plist`);
      run('security', ['cms', '-D', '-i', profilePath, '-o', xmlPath], `${secretName}-decode`);
      const profileXml = readFileSync(xmlPath, 'utf8');
      run('plutil', ['-lint', xmlPath], `${secretName}-plist-validation`);
      const extract = (key, format) => run('plutil', ['-extract', key, format, '-o', '-', xmlPath], `${secretName}-${key.replaceAll('.', '-')}`).trim();
      const profile = {
        TeamIdentifier: JSON.parse(extract('TeamIdentifier', 'json')),
        Entitlements: JSON.parse(extract('Entitlements', 'json')),
        UUID: extract('UUID', 'raw'),
        ExpirationDate: extract('ExpirationDate', 'raw')
      };
      assert.equal(profile.TeamIdentifier[0], requireSecret('APPLE_TEAM_ID'));
      assert.equal(profile.Entitlements['application-identifier'], `${profile.TeamIdentifier[0]}.${bundleId}`);
      assert.equal(profile.Entitlements['get-task-allow'], false);
      assert.equal(profile.ProvisionedDevices, undefined);
      assert.equal(profile.ProvisionsAllDevices, undefined);
      assert.ok(!/<key>\s*(ProvisionedDevices|ProvisionsAllDevices)\s*<\/key>/.test(profileXml), 'App Store profiles must not contain device-list distribution settings');
      assert.ok(Date.parse(profile.ExpirationDate) > Date.now());
      profiles.push(profile);
      for (const folder of ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles']) {
        const destinationDirectory = path.join(os.homedir(), folder);
        mkdirSync(destinationDirectory, { recursive: true, mode: 0o700 });
        const destination = path.join(destinationDirectory, `${profile.UUID}.mobileprovision`);
        state.installedProfiles.push(destination);
        saveState(state);
        writePrivate(destination, readFileSync(profilePath));
      }
    }
    const keychainPassword = randomBytes(32).toString('base64');
    run('security', ['create-keychain', '-p', keychainPassword, keychainPath], 'keychain-create');
    run('security', ['set-keychain-settings', '-lut', '21600', keychainPath], 'keychain-settings');
    run('security', ['unlock-keychain', '-p', keychainPassword, keychainPath], 'keychain-unlock');
    run('security', ['import', certificatePath, '-P', requireSecret('IOS_SIGNING_CERTIFICATE_PASSWORD'), '-k', keychainPath, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'], 'certificate-import');
    run('security', ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-k', keychainPassword, keychainPath], 'key-partitions');
    run('security', ['list-keychains', '-d', 'user', '-s', keychainPath, ...previousKeychains], 'keychain-search-configure');
    const identities = run('security', ['find-identity', '-v', '-p', 'codesigning', keychainPath], 'signing-identities');
    assert.match(identities, /1 valid identities found/, 'Exactly one valid distribution identity is required');
    state.buildNumber = `${environment.GITHUB_RUN_NUMBER}.${environment.GITHUB_RUN_ATTEMPT}`;
    state.teamId = requireSecret('APPLE_TEAM_ID');
    state.profileUuids = standalone ? { [standalone.target]: profiles[0].UUID }
      : { PhrabitCapture: profiles[0].UUID, PhrabitCaptureControl: profiles[1].UUID };
    state.previewAuthOnly = Boolean(previewSettings);
    state.audioPilotMode = pilotMode;
    state.audioPilotVariant = pilotVariant;
    state.offlineInternalVariant = offlineVariant;
    const spec = standalone ? standaloneDistributionSpec(standalone, state.teamId, profiles[0].UUID, state.buildNumber)
      : distributionSpec(state.teamId, profiles[0].UUID, profiles[1].UUID, state.buildNumber, previewSettings, offlineVariant, pilotVariant);
    writeFileSync(path.join(prototype, 'distribution.json'), JSON.stringify(spec), { mode: 0o600 });
    const provisioningProfiles = Object.fromEntries(requiredProfiles.map(([, bundleId], index) => [bundleId, profiles[index].UUID]));
    const options = { method: 'app-store-connect', teamID: state.teamId, signingStyle: 'manual', signingCertificate: 'Apple Distribution', manageAppVersionAndBuildNumber: false, provisioningProfiles };
    if (previewSettings || offline) options.testFlightInternalTestingOnly = true;
    if (pilotMode || offline) options.destination = 'export';
    writePrivate(path.join(privateRoot, 'export.json'), JSON.stringify(options));
    run('plutil', ['-convert', 'xml1', '-o', path.join(privateRoot, 'ExportOptions.plist'), path.join(privateRoot, 'export.json')], 'export-options');
    saveState(state);
    console.log(`Signing material imported into an ephemeral keychain; ${profiles.length} target profiles validated.`);
  } else if (stage === 'build') {
    const state = readState();
    const standalone = standaloneBuilds.get(state.offlineInternalVariant);
    if (standalone) {
      const { target, inspection } = standalone;
      const inspectDevicePackage = (appPath, label) => {
        assert.ok(!existsSync(path.join(appPath, 'PlugIns')), 'The standalone app must not contain extensions');
        run('codesign', ['--verify', '--strict', appPath], label + '-verify');
        const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(appPath, 'Info.plist')], label + '-info'));
        const signedEntitlements = path.join(privateRoot, label + '-entitlements.plist');
        run('codesign', ['-d', '--xml', '--entitlements', signedEntitlements, appPath], label + '-entitlements');
        assert.ok(existsSync(signedEntitlements), 'Signed app does not contain entitlements');
        const entitlements = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', signedEntitlements], label + '-entitlements-plist'));
        assertGuestDeviceProbeBundle(info, readFileSync(path.join(appPath, target)), entitlements, state.teamId, state.buildNumber);
      };
      assert.ok(state.previewAuthOnly === false && state.audioPilotMode === null && state.audioPilotVariant === 'none');
      const appUuid = state.profileUuids[target];
      assert.deepEqual(state.profileUuids, { [target]: appUuid });
      const spec = JSON.parse(readFileSync(path.join(prototype, 'distribution.json'), 'utf8'));
      assert.deepEqual(spec, standaloneDistributionSpec(standalone, state.teamId, appUuid, state.buildNumber));
      assert.match(run('xcodebuild', ['-version'], 'xcode-version'), /^Xcode 26\./);
      assert.match(run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-version'], 'ios-sdk'), /^26\./);
      assert.deepEqual(assertInternalExport(true).provisioningProfiles, { 'com.phrabit.app': appUuid });
      run('xcodegen', ['generate', '--spec', 'distribution.json'], 'connection-project-generate');
      const settings = JSON.parse(run('xcodebuild', targetSettingsArguments(target), 'standalone-build-settings'))
        .find(entry => entry.target === target)?.buildSettings;
      assert.ok(settings, 'Missing standalone connection build settings');
      assert.equal(settings.PRODUCT_BUNDLE_IDENTIFIER, 'com.phrabit.app');
      assert.equal(settings.CODE_SIGNING_ALLOWED, 'YES');
      assert.equal(settings.CODE_SIGN_STYLE, 'Manual');
      assert.equal(settings.CODE_SIGN_IDENTITY, 'Apple Distribution');
      assert.ok(settings.DEVELOPMENT_TEAM === state.teamId && settings.PROVISIONING_PROFILE_SPECIFIER === appUuid);
      assert.equal(settings.CURRENT_PROJECT_VERSION, state.buildNumber);
      const archivePath = path.join(privateRoot, target + '.xcarchive');
      run('xcodebuild', ['-project', target + '.xcodeproj', '-scheme', target, '-configuration', 'Release',
        '-destination', 'generic/platform=iOS', '-archivePath', archivePath, '-derivedDataPath', path.join(privateRoot, 'DerivedData'),
        `OTHER_CODE_SIGN_FLAGS=--keychain ${keychainPath}`, 'archive'], 'connection-archive');
      const appPath = path.join(archivePath, 'Products/Applications', target + '.app');
      const executablePath = path.join(appPath, target);
      assert.ok(!existsSync(path.join(appPath, 'PlugIns')), 'The standalone app must not contain extensions');
      if (target === deviceTarget) {
        inspectDevicePackage(appPath, 'device-archive');
      } else {
        const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(appPath, 'Info.plist')], 'connection-bundle-info'));
        assertGuestConnectionBundle(info, readFileSync(executablePath), state.buildNumber);
        run('codesign', ['--verify', '--strict', appPath], 'standalone-signature');
      }
      const links = run('xcrun', ['otool', '-L', executablePath], 'connection-links');
      const symbols = run('xcrun', ['nm', '-m', executablePath], 'connection-symbols');
      inspectEncryptionEvidence(links, symbols);
      state.ipaPath = exportArchive(archivePath);
      if (target === deviceTarget) {
        const exported = path.join(privateRoot, 'exported-probe');
        run('ditto', ['-x', '-k', state.ipaPath, exported], 'device-ipa-unpack');
        inspectDevicePackage(path.join(exported, 'Payload', target + '.app'), 'device-ipa');
      }
      state.offlineInspectionPassed = true;
      state[inspection] = true;
      saveState(state);
      console.log(`Signed ${state.offlineInternalVariant} build ${state.buildNumber} exported for internal testing. No recording, extension, or export answers embedded.`);
      return;
    }
    const infoProperties = JSON.parse(readFileSync(path.join(prototype, 'distribution.json'), 'utf8')).targets.PhrabitCapture.info.properties;
    const settings = infoProperties.PhrabitPreviewAuthOnly;
    const offline = offlineBuild(state.offlineInternalVariant);
    const offlineStartupTiming = state.offlineInternalVariant === 'startup-timing';
    for (const variant of offlineBuilds.values()) {
      assert.equal(infoProperties[variant.marker], variant === offline ? true : undefined, 'Offline build marker does not match runner state');
    }
    if (offline) assert.ok(!settings && state.previewAuthOnly === false && state.audioPilotMode === null);
    assert.ok([null, 'archive', 'internal-upload'].includes(state.audioPilotMode), 'Invalid runner audio pilot mode');
    const audioPilot = settings?.ConnectionCheck === audioPilotContract;
    assert.equal(audioPilot, state.audioPilotMode !== null, 'Archive mode does not match Preview settings');
    assertAudioPilotVariant(state.audioPilotVariant, audioPilot);
    const translationHomePilot = state.audioPilotVariant === 'translation-home';
    assert.equal(infoProperties[translationHomePilotMarker], translationHomePilot ? true : undefined, 'Preview translation home marker does not match runner state');
    assert.match(run('xcodebuild', ['-version'], 'xcode-version'), /^Xcode 26\./);
    assert.match(run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-version'], 'ios-sdk'), /^26\./);
    if (state.previewAuthOnly || offline) {
      if (state.previewAuthOnly) run('plutil', ['-replace', 'NSPrivacyCollectedDataTypes', '-json', JSON.stringify(previewAuthPrivacyCategories(settings)), 'App/PrivacyInfo.xcprivacy'], 'preview-auth-privacy');
      assertInternalExport(audioPilot || offline);
    }
    if (offlineStartupTiming) {
      const controlManifest = 'Control/PrivacyInfo.xcprivacy';
      const types = JSON.parse(run('plutil', ['-extract', 'NSPrivacyAccessedAPITypes', 'json', '-o', '-', controlManifest], 'control-privacy-types'));
      types.push({ NSPrivacyAccessedAPIType: 'NSPrivacyAccessedAPICategorySystemBootTime', NSPrivacyAccessedAPITypeReasons: ['35F9.1'] });
      run('plutil', ['-replace', 'NSPrivacyAccessedAPITypes', '-json', JSON.stringify(types), controlManifest], 'control-timing-privacy');
    }
    run('xcodegen', ['generate', '--spec', 'distribution.json'], 'project-generate');
    const inspectedBuild = audioPilot || Boolean(offline);
    const pinnedDependencies = inspectedBuild ? ['-onlyUsePackageVersionsFromResolvedFile'] : [];
    const archiveLock = path.join(prototype, 'PhrabitCapture.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');
    let checkedInRevisions;
    if (inspectedBuild) {
      const checkedInLock = run('git', ['show', 'HEAD:native/ios/PhrabitCapture/Core/Package.resolved'], 'checked-in-core-dependencies');
      checkedInRevisions = dependencyRevisions(checkedInLock);
      assert.deepEqual(dependencyRevisions(readFileSync(path.join(prototype, 'Core/Package.resolved'), 'utf8')), checkedInRevisions);
      mkdirSync(path.dirname(archiveLock), { recursive: true });
      writeFileSync(archiveLock, checkedInLock);
    }
    for (const target of ['PhrabitCapture', 'PhrabitCaptureControl']) {
      const generatedSettings = JSON.parse(run('xcodebuild', [...targetSettingsArguments(target), ...pinnedDependencies], `generated-signing-settings-${target}`));
      const targetSettings = generatedSettings.find((entry) => entry.target === target)?.buildSettings;
      assert.ok(targetSettings, 'Missing expected target build settings');
      assert.equal(targetSettings.CODE_SIGN_STYLE, 'Manual', 'Target must use manual distribution signing');
      assert.equal(targetSettings.CODE_SIGN_IDENTITY, 'Apple Distribution', 'Target selected the wrong certificate type');
      assert.ok(targetSettings.DEVELOPMENT_TEAM === state.teamId, 'Target selected the wrong team');
      assert.ok(targetSettings.PROVISIONING_PROFILE_SPECIFIER === state.profileUuids[target], 'Target selected the wrong profile');
      assert.equal(targetSettings.CURRENT_PROJECT_VERSION, state.buildNumber, 'Target build version mismatch');
      const conditions = (targetSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS ?? '').split(/\s+/);
      assert.equal(conditions.includes(audioPilotFlag), audioPilot && target === 'PhrabitCapture', 'Audio pilot flag must be app-only');
      assert.equal(conditions.includes(translationHomePilotFlag), translationHomePilot && target === 'PhrabitCapture', 'Preview translation home flag must match the selected app variant');
      for (const variant of offlineBuilds.values()) {
        assert.equal(conditions.includes(variant.flag), variant === offline, 'Offline flags must match both targets');
      }
    }
    console.log('Manual distribution identity, team, profile, and build version verified for both targets.');
    const archivePath = path.join(privateRoot, 'PhrabitCapture.xcarchive');
    run('xcodebuild', ['-project', 'PhrabitCapture.xcodeproj', '-scheme', 'PhrabitCapture', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archivePath, '-derivedDataPath', path.join(privateRoot, 'DerivedData'), ...pinnedDependencies, `OTHER_CODE_SIGN_FLAGS=--keychain ${keychainPath}`, 'archive'], 'signed-archive');
    if (inspectedBuild) assert.deepEqual(dependencyRevisions(readFileSync(archiveLock, 'utf8')), checkedInRevisions);
    const appPath = path.join(archivePath, 'Products/Applications/PhrabitCapture.app');
    const controlPath = path.join(appPath, 'PlugIns/PhrabitCaptureControl.appex');
    let appleCryptoLink = false;
    for (const [bundlePath, identifier] of [[appPath, 'com.phrabit.app'], [controlPath, 'com.phrabit.app.control']]) {
      assert.equal(run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(bundlePath, 'Info.plist')], `${identifier}-id`).trim(), identifier);
      assert.ok(existsSync(path.join(bundlePath, 'PrivacyInfo.xcprivacy')));
      assert.equal(run('plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', path.join(bundlePath, 'Info.plist')], `${identifier}-build-version`).trim(), state.buildNumber, 'Bundle build version mismatch');
      assert.equal(run('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', path.join(bundlePath, 'Info.plist')], `${identifier}-marketing-version`).trim(), '0.1.0', 'Bundle marketing version mismatch');
      run('codesign', ['--verify', '--strict', bundlePath], `${identifier}-signature`);
      if (inspectedBuild) {
        const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(bundlePath, 'Info.plist')], `${identifier}-inspection-info`));
        assert.ok(!('ITSAppUsesNonExemptEncryption' in info) && !('ITSEncryptionExportComplianceCode' in info), 'Export compliance answers must not be injected by CI');
        assert.equal(info[translationHomePilotMarker], translationHomePilot && identifier === 'com.phrabit.app' ? true : undefined, 'Signed bundle has an incorrect Preview translation home marker');
        if (offline) {
          for (const variant of offlineBuilds.values()) {
            assert.equal(info[variant.marker], variant === offline ? true : undefined, 'Signed bundle has an incorrect offline marker');
          }
          assert.ok(!('PhrabitPreviewAuthOnly' in info) && !('PhrabitDiagnosticsOnly' in info), 'Offline archive must not contain Preview settings');
          if (identifier === 'com.phrabit.app') assert.equal(info.NSMicrophoneUsageDescription, offline.microphone);
          if (state.offlineInternalVariant === offlineGuestVariant) assert.deepEqual(info.CFBundleURLTypes ?? [], [], 'Guest builds must not register a sign-in callback');
          const privacyManifest = path.join(bundlePath, 'PrivacyInfo.xcprivacy');
          const privacy = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', privacyManifest], `${identifier}-offline-privacy`));
          assert.deepEqual(privacy.NSPrivacyCollectedDataTypes, []);
          assert.equal(privacy.NSPrivacyTracking, false);
          if (offlineStartupTiming) {
            assert.ok(privacy.NSPrivacyAccessedAPITypes.some(entry => entry.NSPrivacyAccessedAPIType === 'NSPrivacyAccessedAPICategorySystemBootTime'));
          }
        }
        assert.match(info.CFBundleExecutable ?? '', /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/);
        const executable = path.join(bundlePath, info.CFBundleExecutable);
        const frameworks = path.join(bundlePath, 'Frameworks');
        if (existsSync(frameworks)) {
          assert.ok(readdirSync(frameworks).every(name => /^libswift[\w+.-]*\.dylib$/.test(name)), 'An unreviewed bundled framework requires manual review');
        }
        const links = run('xcrun', ['otool', '-L', executable], `${identifier}-linked-libraries`);
        const symbols = run('xcrun', ['nm', '-m', executable], `${identifier}-symbols`);
        appleCryptoLink = inspectEncryptionEvidence(links, symbols) || appleCryptoLink;
      }
    }
    if (state.previewAuthOnly) {
      const bundled = JSON.parse(run('plutil', ['-extract', 'PhrabitPreviewAuthOnly', 'json', '-o', '-', path.join(appPath, 'Info.plist')], 'preview-auth-bundle'));
      assert.ok(bundled.ProjectRef === settings.ProjectRef && bundled.PublishableKey === settings.PublishableKey &&
        bundled.ConnectionCheck === settings.ConnectionCheck && bundled.LocalMockRecording === settings.LocalMockRecording &&
        Object.keys(bundled).length === Object.keys(settings).length, 'Preview bundle configuration mismatch');
      const extensionInfo = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(controlPath, 'Info.plist')], 'control-info'));
      assert.ok(!('PhrabitPreviewAuthOnly' in extensionInfo), 'Preview configuration must be app-only');
      if (audioPilot) {
        const appInfo = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(appPath, 'Info.plist')], 'audio-pilot-app-info'));
        assert.equal(appInfo.NSMicrophoneUsageDescription, audioPilotMicrophoneDescription);
        assert.ok(!('PhrabitDiagnosticsOnly' in appInfo) && !('PhrabitDiagnosticsOnly' in extensionInfo));
        assert.ok(!('LocalMockRecording' in bundled));
        const controlPrivacy = JSON.parse(run('plutil', ['-extract', 'NSPrivacyCollectedDataTypes', 'json', '-o', '-', path.join(controlPath, 'PrivacyInfo.xcprivacy')], 'audio-pilot-control-privacy'));
        assert.deepEqual(controlPrivacy, []);
      }
      if (settings.ConnectionCheck === 'capture-audio-diagnostics-v1') {
        const appInfo = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(appPath, 'Info.plist')], 'diagnostics-app-info'));
        assert.ok(appInfo.PhrabitDiagnosticsOnly === true && extensionInfo.PhrabitDiagnosticsOnly === true, 'Diagnostics must disable recording in app and control');
        assert.equal(appInfo.NSMicrophoneUsageDescription, 'この接続検証版はマイクを使用しません。');
        assert.ok(!('LocalMockRecording' in bundled), 'Diagnostics cannot include recording');
        console.log('Connection diagnostics only; recording disabled in the app and control.');
      }
      const bundledPrivacy = JSON.parse(run('plutil', ['-extract', 'NSPrivacyCollectedDataTypes', 'json', '-o', '-', path.join(appPath, 'PrivacyInfo.xcprivacy')], 'preview-auth-bundled-privacy'));
      assert.deepEqual(bundledPrivacy, previewAuthPrivacyCategories(settings));
    }
    state.ipaPath = exportArchive(archivePath);
    if (audioPilot) {
      assert.ok(appleCryptoLink, 'Expected iOS cryptographic framework link was not found');
      state.audioPilotInspectionPassed = state.audioPilotVariant;
      console.log(`Signed audio pilot ${state.audioPilotVariant} inspection: locked dependencies verified, Apple OS crypto links found, no known bundled non-OS indicators, no export answers embedded.`);
    }
    if (offline) {
      state.offlineInspectionPassed = true;
      console.log(`Signed offline ${state.offlineInternalVariant} inspection: internal-only export, locked dependencies, offline settings only, no export answers embedded.`);
    }
    saveState(state);
    console.log(`Signed iPhone build ${state.buildNumber} exported; app and control signatures verified.`);
  } else if (stage === 'upload' || stage === 'upload-audio-pilot' || stage === 'upload-offline') {
    const state = readState();
    const requestedOfflineVariant = stage === 'upload-offline' ? offlineInternalVariant(environment) : 'none';
    assert.ok(stage !== 'upload-offline' || requestedOfflineVariant !== 'none', 'Explicit offline variant required for offline upload');
    const requestedPilotVariant = stage === 'upload-audio-pilot' ? environment.IOS_AUDIO_PILOT_VARIANT : 'none';
    if (stage === 'upload-audio-pilot') assert.equal(audioPilotMode(environment), 'internal-upload', 'Explicit internal audio pilot upload action required');
    assertTestFlightUploadAllowed(state, requestedPilotVariant, requestedOfflineVariant);
    assert.ok(state.ipaPath?.startsWith(privateRoot + path.sep));
    assert.match(requireSecret('ASC_KEY_ID'), /^[A-Z0-9]{10}$/);
    assert.match(requireSecret('ASC_ISSUER_ID'), /^[a-f0-9-]{36}$/i);
    const keyDirectory = path.join(os.homedir(), '.appstoreconnect/private_keys');
    mkdirSync(keyDirectory, { recursive: true, mode: 0o700 });
    state.apiKeyPath = path.join(keyDirectory, `AuthKey_${environment.ASC_KEY_ID}.p8`);
    saveState(state);
    writePrivate(state.apiKeyPath, Buffer.from(requireSecret('ASC_PRIVATE_KEY_BASE64'), 'base64'));
    run('xcrun', ['altool', '--upload-app', '--type', 'ios', '-f', state.ipaPath, '--apiKey', environment.ASC_KEY_ID, '--apiIssuer', environment.ASC_ISSUER_ID], 'apple-upload');
    console.log(`Build ${state.buildNumber} uploaded to App Store Connect. Processing and internal tester availability require separate verification.`);
  } else {
    throw new Error('Unknown distribution stage');
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv[2]); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
