import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const prototypeRoot = path.join(root, "native/ios/PhrabitCapture");
const read = (relativePath) => readFileSync(path.join(prototypeRoot, relativePath), "utf8");

function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith(".") || entry.name === "build" || entry.name === "Generated") return [];
    const entryPath = path.join(directory, entry.name);
    return entry.isDirectory() ? listFiles(entryPath) : [entryPath];
  });
}

const checks = [
  ["iOS 18+ with application and embedded control targets", () => {
    const project = read("project.yml");
    assert.match(project, /iOS: "18\.0"/);
    assert.match(project, /type: application/);
    assert.match(project, /type: app-extension/);
    assert.match(project, /target: PhrabitCaptureControl\s+embed: true/);
    assert.match(project, /NSMicrophoneUsageDescription:/);
    assert.doesNotMatch(project, /UIBackgroundModes|NSSupportsLiveActivities|app-groups/);
  }],
  ["intent sources belong to both targets", () => {
    assert.equal((read("project.yml").match(/^      - Shared$/gm) ?? []).length, 2);
    assert.match(read("Shared/OpenRecorderIntent.swift"), /OpenIntent/);
    assert.match(read("Shared/OpenRecorderIntent.swift"), /requiresLocalDeviceAuthentication/);
    assert.match(read("Shared/OpenRecorderIntent.swift"), /CaptureLaunchRequest\.enqueue/);
    assert.match(read("App/PhrabitCaptureApp.swift"), /handlePendingLaunch/);
  }],
  ["registered application and control identifiers stay aligned", () => {
    const identifiers = [...read("project.yml").matchAll(/PRODUCT_BUNDLE_IDENTIFIER: ([^\s]+)/g)]
      .map((match) => match[1]);
    assert.deepEqual(identifiers, ["com.phrabit.app", "com.phrabit.app.control"]);
    assert.doesNotMatch(read("project.yml"), /com\.phrabit\.quickcapture\.prototype/);
  }],
  ["application supports rotation without a deprecated fullscreen requirement", () => {
    const project = read("project.yml");
    const orientations = [...project.matchAll(/^          - (UIInterfaceOrientation\w+)$/gm)]
      .map((match) => match[1]);
    assert.deepEqual(orientations, [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationPortraitUpsideDown",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight"
    ]);
    assert.doesNotMatch(project, /UIRequiresFullScreen/);
  }],
  ["default application remains offline; dormant client has no embedded credentials or origin", () => {
    const swiftSources = listFiles(prototypeRoot)
      .filter((file) => file.endsWith(".swift") && path.basename(file) !== "Package.swift" && !file.includes(`${path.sep}Tests${path.sep}`))
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
    assert.doesNotMatch(swiftSources, /https?:\/\/|GEMINI_API_KEY|OPENAI_API_KEY|SUPABASE|import Speech|FoundationModels/);
    assert.match(read("App/CaptureViewModel.swift"), /processor \?\? MockCaptureProcessor\(\)/);
    assert.doesNotMatch(read("App/CaptureViewModel.swift") + read("App/PhrabitCaptureApp.swift"), /CaptureHTTPProcessor\(/);
    assert.match(read("App/CapturePreviewAuthView.swift"), /mode = \.offline\(CaptureViewModel\(\), \.mock\(\)\)/);
    assert.match(read("App/CaptureView.swift"), /模擬翻訳・音声は送信しません/);
    assert.match(read("App/CaptureView.swift"), /サンプル入力・録音内容ではありません/);
  }],
  ["auth uses an exact stable SDK version and keeps configuration outside the default app", () => {
    assert.match(read("Core/Package.swift"), /exact: "2\.55\.7"/);
    const pins = JSON.parse(read("Core/Package.resolved")).pins;
    const sdk = pins.find((pin) => pin.identity === "supabase-swift");
    assert.equal(sdk.state.version, "2.55.7");
    assert.equal(sdk.state.revision, "ed28cff9d3d246f54ebe75e52a7334e0a2f366de");
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureSupabaseAuthentication.swift"), /flowType: \.pkce/);
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureSupabaseAuthentication.swift"), /autoRefreshToken: false/);
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureSupabaseAuthentication.swift"), /try scope\.takeRequest\(\)/);
    assert.doesNotMatch(read("App/PhrabitCaptureApp.swift"), /CaptureLiveConnection|CaptureAuthConfiguration\(/);
  }],
  ["consent, keyed storage and callback guards are explicit", () => {
    const access = read("Core/Sources/PhrabitCaptureCore/CaptureAccess.swift");
    assert.match(access, /guard consentAccepted/);
    assert.match(access, /generation == expectedGeneration/);
    assert.match(access, /CaptureEnvironmentStorage/);
    assert.match(read("App/CaptureAccessView.swift"), /OpenAI/);
    assert.match(read("App/CaptureAccessView.swift"), /Google/);
    assert.match(read("App/CaptureAccessView.swift"), /送信同意を取り消す/);
    assert.match(read("App/CaptureAccessView.swift"), /模擬ログイン/);
    assert.match(read("App/CaptureBrowserLogin.swift"), /ASWebAuthenticationSession/);
    assert.match(read("project.yml"), /CFBundleURLSchemes:\s+- com\.phrabit\.app/);
    assert.doesNotMatch(read("App/CaptureCredentialStore.swift"), /UserDefaults|print\(/);
  }],
  ["native networking requires consent and token and disables redirects and disk caches", () => {
    const client = read("Core/Sources/PhrabitCaptureCore/CaptureHTTPProcessor.swift");
    assert.match(client, /URLSessionConfiguration\.ephemeral/);
    assert.match(client, /configuration\.urlCache = nil/);
    assert.match(client, /completionHandler\(nil\)/);
    assert.match(client, /guard consentGranted\(\)/);
    assert.match(client, /Task\.checkCancellation/);
    assert.match(read("App/CaptureCredentialStore.swift"), /kSecAttrAccessibleWhenUnlockedThisDeviceOnly/);
    assert.doesNotMatch(read("App/CaptureCredentialStore.swift"), /UserDefaults|print\(/);
    assert.match(read("Core/Tests/PhrabitCaptureCoreTests/CaptureHTTPProcessorTests.swift"), /URLProtocol/);
  }],
  ["recording capped, permission requested, files protected and discarded", () => {
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureSession.swift"), /maximumRecordingDuration: TimeInterval = 20/);
    const recorder = read("App/AudioRecorder.swift");
    assert.match(recorder, /AVAudioApplication\.requestRecordPermission/);
    assert.match(recorder, /record\(forDuration: CaptureSession\.maximumRecordingDuration\)/);
    assert.match(recorder, /FileProtectionType\.complete/);
    assert.match(recorder, /removeItem\(at: url\)/);
    assert.match(read("App/CaptureViewModel.swift"), /defer \{ try\? FileManager\.default\.removeItem\(at: recordingURL\) \}/);
  }],
  ["connection checks are manual, consent-gated, non-saving and reject deployment protection without logging out", () => {
    const verifier = read("Core/Sources/PhrabitCaptureCore/CaptureConnectionVerifier.swift");
    assert.match(verifier, /api\/capture\/access/);
    assert.match(verifier, /request\.httpMethod = "GET"/);
    assert.match(verifier, /access\.canRecord/);
    assert.match(verifier, /access\.sessionRevision == revision/);
    assert.match(verifier, /capture-access-v1/);
    assert.doesNotMatch(verifier, /httpBody =|transcribe\(|translate\(|print\(|retry/);
    assert.match(read("App/CaptureAccessView.swift"), /接続を確認（音声を送らない）/);
    assert.doesNotMatch(read("App/CaptureViewModel.swift"), /diagnostics|CaptureConnectionVerifier|\.verify\(/);
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureHTTPProcessor.swift"), /isCaptureError/);
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureConnectionDiagnostics.swift"), /self\.access\.sessionRevision == revision/);
    assert.match(read("Core/Tests/PhrabitCaptureCoreTests/CaptureHTTPProcessorTests.swift"), /testProtectedDeploymentDoesNotLookLikeAnExpiredLogin/);
  }],
  ["language choice persists, with fixed English and Chinese fixtures", () => {
    assert.match(read("App/CaptureViewModel.swift"), /UserDefaults\.standard\.set\(language\.rawValue/);
    const fixtures = read("Core/Sources/PhrabitCaptureCore/MockTranslator.swift");
    assert.match(fixtures, /case \.english:/);
    assert.match(fixtures, /case \.chinese:/);
    assert.match(fixtures, /reading: nil/);
    assert.match(fixtures, /reading: "Kěyǐ/);
  }],
  ["signed preview auth variant can only check the account or the bounded diagnostic API", () => {
    const app = read("App/PhrabitCaptureApp.swift");
    const preview = read("App/CapturePreviewAuthView.swift");
    const verifier = read("Core/Sources/PhrabitCaptureCore/CaptureConnectionVerifier.swift");
    const distribution = readFileSync(path.join(root, "scripts/ios-testflight.mjs"), "utf8");
    const workflow = readFileSync(path.join(root, ".github/workflows/ios-testflight.yml"), "utf8");
    assert.match(app, /case \.offline\(let model, let access\):\s+recordingView/);
    assert.match(preview, /mode = \.offline/);
    assert.match(preview, /CaptureConnectionVerifier\(previewAuth:/);
    assert.match(verifier, /auth\/v1\/user/);
    assert.match(verifier, /functions\/v1\/phrabit-capture-check/);
    assert.match(verifier, /capture-edge-v1/);
    assert.doesNotMatch(preview, /AudioRecorder|\/api\/capture/);
    assert.doesNotMatch(read("project.yml"), /PhrabitPreviewAuthOnly/);
    assert.match(distribution, /Approved isolated Preview project only/);
    assert.match(distribution, /testFlightInternalTestingOnly = true/);
    assert.match(workflow, /preview_auth_only:[\s\S]*?default: false/);
    assert.match(workflow, /preview_capture_check:[\s\S]*?default: false/);
  }],
  ["local live audio requires an explicit compile flag, a different consent namespace and sealed signing defaults", () => {
    const preview = read("App/CapturePreviewAuthView.swift");
    const processor = read("Core/Sources/PhrabitCaptureCore/CaptureHTTPProcessor.swift");
    const distribution = readFileSync(path.join(root, "scripts/ios-testflight.mjs"), "utf8");
    const workflow = readFileSync(path.join(root, ".github/workflows/ios-testflight.yml"), "utf8");
    assert.match(preview, /#if PHRABIT_LOCAL_LIVE_AUDIO\s+let liveAudio = settings\["ConnectionCheck"\] == "capture-audio-preview-v1"\s+#else\s+let liveAudio = false/);
    assert.match(preview, /liveAudio \? "preview-audio-consent-v1" : "preview-auth-only-v1"/);
    assert.match(preview, /else if liveAudio \{\s+guard let processor = try\? CaptureHTTPProcessor\(previewAudio:/);
    assert.match(processor, /project == configuration\.apiOrigin/);
    assert.match(processor, /response\.url == destination/);
    assert.doesNotMatch(processor, /x-vercel-protection-bypass/);
    for (const settings of [distribution, workflow, read("project.yml")]) {
      assert.doesNotMatch(settings, /PHRABIT_LOCAL_LIVE_AUDIO|capture-audio-preview-v1/);
    }
  }],
  ["opt-in Preview recording requires proof, retains no audio, and uses a fresh lock-screen request", () => {
    const preview = read("App/CapturePreviewAuthView.swift");
    const model = read("App/CaptureViewModel.swift");
    const access = read("Core/Sources/PhrabitCaptureCore/CaptureAccess.swift");
    const workflow = readFileSync(path.join(root, ".github/workflows/ios-testflight.yml"), "utf8");
    assert.match(preview, /usesCaptureEdge && settings\["LocalMockRecording"\] == "true"/);
    assert.match(preview, /try await verifier\.verify\(\)[\s\S]*?confirmLocalRecording\(afterCheckFor: revision\)/);
    assert.match(preview, /CaptureViewModel\(processor: MockCaptureProcessor\(\), recordingAllowed: \{ access\.canRecordLocally \}\)/);
    assert.match(access, /canRecord && userID == localRecordingOwner/);
    assert.match(model, /if self\.processor\.sendsAudio \{\s+audio = try Data\(contentsOf: recordingURL\)\s+try FileManager\.default\.removeItem\(at: recordingURL\)\s+\} else \{\s+self\.recorder\.discard\(recordingURL\)\s+audio = Data\(\)/);
    assert.match(read("App/AudioRecorder.swift"), /guard authorized\(\)/);
    assert.match(read("Shared/CaptureLaunchRequest.swift"), /\(0\.\.\.30\)\.contains\(age\)/);
    assert.match(workflow, /preview_mock_recording:[\s\S]*?default: false/);
  }],
  ["Phrabit custom symbol asset referenced by the control", () => {
    const asset = JSON.parse(read("Shared/Assets.xcassets/PhrabitControl.symbolset/Contents.json"));
    assert.equal(asset.symbols[0].filename, "PhrabitControl.svg");
    const symbol = read("Shared/Assets.xcassets/PhrabitControl.symbolset/PhrabitControl.svg");
    assert.match(symbol, /id="Regular-M"/);
    for (const size of ["S", "M", "L"]) {
      assert.ok(symbol.includes(`id="Baseline-${size}"`));
      assert.ok(symbol.includes(`id="Capline-${size}"`));
    }
    assert.match(read("Control/PhrabitCaptureControl.swift"), /Image\("PhrabitControl"\)/);
    const appIcon = JSON.parse(read("App/Assets.xcassets/AppIcon.appiconset/Contents.json"));
    assert.equal(appIcon.images[0].size, "1024x1024");
    assert.equal(appIcon.images[0].filename, "AppIcon.png");
  }],
  ["cloud build is manual, gated, unsigned, and non-distributing", () => {
    const workflow = readFileSync(path.join(root, ".github/workflows/ios-prototype.yml"), "utf8");
    assert.match(workflow, /workflow_dispatch:/);
    assert.match(workflow, /default: false/);
    assert.match(workflow, /if: \$\{\{ inputs\.confirm_usage \}\}/);
    assert.match(workflow, /timeout-minutes: 20/);
    assert.match(workflow, /CODE_SIGNING_ALLOWED=NO/);
    assert.match(workflow, /runs-on: macos-26/);
    assert.match(workflow, /DEVELOPER_DIR: \/Applications\/Xcode_26\.2\.app\/Contents\/Developer/);
    assert.match(workflow, /Verify distribution-compatible toolchain/);
    assert.match(workflow, /Verify bundled privacy manifests/);
    assert.match(workflow, /node --test scripts\/ios-public-export-policy\.test\.mjs/);
    assert.match(workflow, /Build unsigned iPhone archive/);
    assert.match(workflow, /generic\/platform=iOS'/);
    assert.match(workflow, /Verify unsigned iPhone archive identifiers and privacy/);
    assert.match(workflow, /UISupportedInterfaceOrientations json/);
    assert.match(workflow, /All interface orientations must be supported/);
    assert.equal((workflow.match(/CODE_SIGNING_ALLOWED=NO/g) ?? []).length, 2);
    assert.doesNotMatch(workflow, /^\s+(push|pull_request|schedule):/m);
    assert.doesNotMatch(workflow, /secrets\.|upload_to_testflight|app-store-connect|vercel|curl|\.env/);
    assert.doesNotMatch(workflow, /upload-artifact|actions\/cache/);
  }],
  ["offline prototype privacy declarations match the native APIs", () => {
    const applicationPrivacy = read("App/PrivacyInfo.xcprivacy");
    const controlPrivacy = read("Control/PrivacyInfo.xcprivacy");
    for (const manifest of [applicationPrivacy, controlPrivacy]) {
      assert.match(manifest, /<key>NSPrivacyTracking<\/key>\s*<false\/>/);
      assert.match(manifest, /<key>NSPrivacyCollectedDataTypes<\/key>\s*<array\/>/);
      assert.match(manifest, /NSPrivacyAccessedAPICategoryUserDefaults/);
      assert.match(manifest, /CA92\.1/);
    }
    assert.match(applicationPrivacy, /NSPrivacyAccessedAPICategorySystemBootTime/);
    assert.match(applicationPrivacy, /35F9\.1/);
    assert.match(applicationPrivacy, /NSPrivacyAccessedAPICategoryFileTimestamp/);
    assert.match(applicationPrivacy, /C617\.1/);
  }]
];

for (const [name, check] of checks) {
  check();
  process.stdout.write(`PASS ${name}\n`);
}
process.stdout.write(`${checks.length} static configuration checks passed. Swift compilation, XCTest, microphone, and lock-screen behavior are NOT verified by this script.\n`);

