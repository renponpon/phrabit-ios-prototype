import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function validateExecution(environment) {
  assert.equal(environment.GITHUB_ACTIONS, 'true', 'GitHub Actions is required');
  assert.equal(environment.GITHUB_REPOSITORY, 'renponpon/phrabit-ios-prototype', 'Dedicated prototype repository only');
  assert.equal(environment.GITHUB_REF, 'refs/heads/main', 'Only main may distribute');
  assert.match(environment.EXPECTED_COMMIT ?? '', /^[a-f0-9]{40}$/, 'A full approved commit is required');
  assert.equal(environment.GITHUB_SHA, environment.EXPECTED_COMMIT, 'Approved commit mismatch');
  assert.ok(environment.RUNNER_TEMP, 'Ephemeral runner storage is required');
}

export function distributionSpec(teamId, appUuid, controlUuid, buildNumber) {
  assert.match(teamId, /^[A-Z0-9]{10}$/);
  assert.match(appUuid, /^[A-F0-9-]{36}$/i);
  assert.match(controlUuid, /^[A-F0-9-]{36}$/i);
  assert.notEqual(appUuid, controlUuid);
  assert.match(buildNumber, /^[1-9]\d{0,3}\.[1-9]\d{0,3}$/);
  const signing = {
    DEVELOPMENT_TEAM: teamId,
    CODE_SIGN_STYLE: 'Manual',
    CODE_SIGN_IDENTITY: 'Apple Distribution',
    'CODE_SIGN_IDENTITY[sdk=iphoneos*]': 'Apple Distribution',
    CURRENT_PROJECT_VERSION: buildNumber,
    MARKETING_VERSION: '0.1.0'
  };
  return {
    include: ['project.yml'],
    settings: { base: signing },
    targets: {
      PhrabitCapture: { settings: { base: { ...signing, PROVISIONING_PROFILE_SPECIFIER: appUuid } } },
      PhrabitCaptureControl: { settings: { base: { ...signing, PROVISIONING_PROFILE_SPECIFIER: controlUuid } } }
    }
  };
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
  assert.ok(['PhrabitCapture', 'PhrabitCaptureControl'].includes(target));
  return ['-project', 'PhrabitCapture.xcodeproj', '-target', target, '-configuration', 'Release', '-sdk', 'iphoneos', '-showBuildSettings', '-json'];
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
    mkdirSync(privateRoot, { mode: 0o700 });
    const previousKeychains = [...run('security', ['list-keychains', '-d', 'user'], 'keychain-search-list').matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    const state = { previousKeychains, installedProfiles: [] };
    saveState(state);
    const certificatePath = path.join(privateRoot, 'certificate.p12');
    writePrivate(certificatePath, Buffer.from(requireSecret('IOS_SIGNING_CERTIFICATE_BASE64'), 'base64'));
    const profiles = [];
    for (const [secretName, bundleId] of [['IOS_APP_PROFILE_BASE64', 'com.phrabit.app'], ['IOS_CONTROL_PROFILE_BASE64', 'com.phrabit.app.control']]) {
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
    state.profileUuids = { PhrabitCapture: profiles[0].UUID, PhrabitCaptureControl: profiles[1].UUID };
    const spec = distributionSpec(requireSecret('APPLE_TEAM_ID'), profiles[0].UUID, profiles[1].UUID, state.buildNumber);
    writeFileSync(path.join(prototype, 'distribution.json'), JSON.stringify(spec), { mode: 0o600 });
    const options = { method: 'app-store-connect', teamID: requireSecret('APPLE_TEAM_ID'), signingStyle: 'manual', signingCertificate: 'Apple Distribution', manageAppVersionAndBuildNumber: false, provisioningProfiles: { 'com.phrabit.app': profiles[0].UUID, 'com.phrabit.app.control': profiles[1].UUID } };
    writePrivate(path.join(privateRoot, 'export.json'), JSON.stringify(options));
    run('plutil', ['-convert', 'xml1', '-o', path.join(privateRoot, 'ExportOptions.plist'), path.join(privateRoot, 'export.json')], 'export-options');
    saveState(state);
    console.log('Signing material imported into an ephemeral keychain; both target profiles validated.');
  } else if (stage === 'build') {
    const state = readState();
    assert.match(run('xcodebuild', ['-version'], 'xcode-version'), /^Xcode 26\./);
    assert.match(run('xcrun', ['--sdk', 'iphoneos', '--show-sdk-version'], 'ios-sdk'), /^26\./);
    run('xcodegen', ['generate', '--spec', 'distribution.json'], 'project-generate');
    for (const target of ['PhrabitCapture', 'PhrabitCaptureControl']) {
      const generatedSettings = JSON.parse(run('xcodebuild', targetSettingsArguments(target), `generated-signing-settings-${target}`));
      const targetSettings = generatedSettings.find((entry) => entry.target === target)?.buildSettings;
      assert.ok(targetSettings, 'Missing expected target build settings');
      assert.equal(targetSettings.CODE_SIGN_STYLE, 'Manual', 'Target must use manual distribution signing');
      assert.equal(targetSettings.CODE_SIGN_IDENTITY, 'Apple Distribution', 'Target selected the wrong certificate type');
      assert.equal(targetSettings.DEVELOPMENT_TEAM, state.teamId, 'Target selected the wrong team');
      assert.equal(targetSettings.PROVISIONING_PROFILE_SPECIFIER, state.profileUuids[target], 'Target selected the wrong profile');
      assert.equal(targetSettings.CURRENT_PROJECT_VERSION, state.buildNumber, 'Target build version mismatch');
    }
    console.log('Manual distribution identity, team, profile, and build version verified for both targets.');
    const archivePath = path.join(privateRoot, 'PhrabitCapture.xcarchive');
    run('xcodebuild', ['-project', 'PhrabitCapture.xcodeproj', '-scheme', 'PhrabitCapture', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', archivePath, '-derivedDataPath', path.join(privateRoot, 'DerivedData'), `OTHER_CODE_SIGN_FLAGS=--keychain ${keychainPath}`, 'archive'], 'signed-archive');
    const appPath = path.join(archivePath, 'Products/Applications/PhrabitCapture.app');
    const controlPath = path.join(appPath, 'PlugIns/PhrabitCaptureControl.appex');
    for (const [bundlePath, identifier] of [[appPath, 'com.phrabit.app'], [controlPath, 'com.phrabit.app.control']]) {
      assert.equal(run('plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', path.join(bundlePath, 'Info.plist')], `${identifier}-id`).trim(), identifier);
      assert.ok(existsSync(path.join(bundlePath, 'PrivacyInfo.xcprivacy')));
      run('codesign', ['--verify', '--strict', bundlePath], `${identifier}-signature`);
    }
    assert.equal(run('plutil', ['-extract', 'CFBundleVersion', 'raw', '-o', '-', path.join(appPath, 'Info.plist')], 'build-version').trim(), state.buildNumber);
    const exportPath = path.join(privateRoot, 'export');
    run('xcodebuild', ['-exportArchive', '-archivePath', archivePath, '-exportPath', exportPath, '-exportOptionsPlist', path.join(privateRoot, 'ExportOptions.plist')], 'ipa-export');
    const packages = readdirSync(exportPath).filter((filename) => filename.endsWith('.ipa'));
    assert.equal(packages.length, 1);
    state.ipaPath = path.join(exportPath, packages[0]);
    saveState(state);
    console.log(`Signed iPhone build ${state.buildNumber} exported; app and control signatures verified.`);
  } else if (stage === 'upload') {
    const state = readState();
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
