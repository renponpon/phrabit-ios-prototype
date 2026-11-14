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
  ["prototype cannot invoke translation or transcription APIs", () => {
    const swiftSources = listFiles(prototypeRoot)
      .filter((file) => file.endsWith(".swift"))
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
    assert.doesNotMatch(swiftSources, /URLSession|https?:\/\/|GEMINI_API_KEY|OPENAI_API_KEY|SUPABASE|import Speech|FoundationModels/);
    assert.match(read("App/CaptureViewModel.swift"), /MockTranslator\(\)/);
    assert.match(read("App/CaptureView.swift"), /模擬翻訳・音声は送信しません/);
    assert.match(read("App/CaptureView.swift"), /サンプル入力・録音内容ではありません/);
  }],
  ["recording capped, permission requested, files protected and discarded", () => {
    assert.match(read("Core/Sources/PhrabitCaptureCore/CaptureSession.swift"), /maximumRecordingDuration: TimeInterval = 20/);
    const recorder = read("App/AudioRecorder.swift");
    assert.match(recorder, /AVAudioApplication\.requestRecordPermission/);
    assert.match(recorder, /record\(forDuration: CaptureSession\.maximumRecordingDuration\)/);
    assert.match(recorder, /FileProtectionType\.complete/);
    assert.match(recorder, /removeItem\(at: url\)/);
    assert.match(read("App/CaptureViewModel.swift"), /defer \{ self\.recorder\.discard\(recordingURL\) \}/);
  }],
  ["language choice persists, with fixed English and Chinese fixtures", () => {
    assert.match(read("App/CaptureViewModel.swift"), /UserDefaults\.standard\.set\(language\.rawValue/);
    const fixtures = read("Core/Sources/PhrabitCaptureCore/MockTranslator.swift");
    assert.match(fixtures, /case \.english:/);
    assert.match(fixtures, /case \.chinese:/);
    assert.match(fixtures, /reading: nil/);
    assert.match(fixtures, /reading: "Kěyǐ/);
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
  }],
  ["cloud build is manual, gated, unsigned, and non-distributing", () => {
    const workflow = readFileSync(path.join(root, ".github/workflows/ios-prototype.yml"), "utf8");
    assert.match(workflow, /workflow_dispatch:/);
    assert.match(workflow, /default: false/);
    assert.match(workflow, /if: \$\{\{ inputs\.confirm_usage \}\}/);
    assert.match(workflow, /timeout-minutes: 20/);
    assert.match(workflow, /CODE_SIGNING_ALLOWED=NO/);
    assert.doesNotMatch(workflow, /^\s+(push|pull_request|schedule):/m);
    assert.doesNotMatch(workflow, /secrets\.|upload_to_testflight|app-store-connect|vercel|curl|\.env/);
    assert.doesNotMatch(workflow, /upload-artifact|actions\/cache/);
  }]
];

for (const [name, check] of checks) {
  check();
  process.stdout.write(`PASS ${name}\n`);
}
process.stdout.write("7 static configuration checks passed. Swift compilation, XCTest, microphone, and lock-screen behavior are NOT verified by this script.\n");

