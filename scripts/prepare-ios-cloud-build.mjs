import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const destination = path.resolve(root, process.argv[2] ?? "tmp/ios-cloud-build-20261114");
const prototype = "native/ios/PhrabitCapture";
const nativeFiles = [
  ".gitignore",
  "README.md",
  "project.yml",
  "App/Assets.xcassets/Contents.json",
  "App/Assets.xcassets/AppIcon.appiconset/Contents.json",
  "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
  "App/AudioRecorder.swift",
  "App/CaptureView.swift",
  "App/CaptureViewModel.swift",
  "App/PhrabitCaptureApp.swift",
  "Control/PhrabitCaptureControl.swift",
  "Core/Package.swift",
  "Core/Sources/PhrabitCaptureCore/CaptureSession.swift",
  "Core/Sources/PhrabitCaptureCore/MockTranslator.swift",
  "Core/Tests/PhrabitCaptureCoreTests/CaptureSessionTests.swift",
  "Shared/CaptureLaunchRequest.swift",
  "Shared/OpenRecorderIntent.swift",
  "Shared/Assets.xcassets/Contents.json",
  "Shared/Assets.xcassets/PhrabitControl.symbolset/Contents.json",
  "Shared/Assets.xcassets/PhrabitControl.symbolset/PhrabitControl.svg"
].map((file) => `${prototype}/${file}`);
const files = [
  ...nativeFiles,
  ".github/workflows/ios-prototype.yml",
  "scripts/check-ios-prototype.mjs",
  "scripts/prepare-ios-cloud-build.mjs",
  "public/icons/icon-512.png"
];

assert.ok(destination.startsWith(path.join(root, "tmp") + path.sep));
mkdirSync(destination, { recursive: true });
assert.equal(readdirSync(destination).length, 0, "搬出先は空である必要があります。既存ファイルを上書きしません。");

const manifest = [];
for (const relativePath of files) {
  const source = path.resolve(root, relativePath);
  const target = path.resolve(destination, relativePath);
  assert.ok(source.startsWith(root));
  assert.ok(target.startsWith(destination + path.sep));
  assert.doesNotMatch(relativePath, /(?:^|\/)(?:\.env[^/]*|\.git|\.vercel|\.private-backups|supabase|src|docs)(?:\/|$)/);
  const contents = readFileSync(source);
  mkdirSync(path.dirname(target), { recursive: true });
  copyFileSync(source, target);
  manifest.push({
    path: relativePath,
    bytes: contents.length,
    sha256: createHash("sha256").update(contents).digest("hex")
  });
}

const readme = [
  "# Phrabit iPhone prototype",
  "",
  "SwiftUIの録音画面とロック画面コントロールの試作です。訳文は固定サンプルで、音声・翻訳APIは呼びません。",
  "",
  "本番Web・DB・認証情報・APIキー・保存データは含みません。署名・TestFlight配布・App Store公開も行いません。",
  "",
  "手動ビルドは標準macOSランナーで行い、ArtifactやCacheは保存しません。",
  "",
  "実装内容・未確認事項・検証手順は [native README](native/ios/PhrabitCapture/README.md) を参照してください。",
  ""
].join("\n");
writeFileSync(path.join(destination, "README.md"), readme);
manifest.push({
  path: "README.md",
  bytes: Buffer.byteLength(readme),
  sha256: createHash("sha256").update(readme).digest("hex")
});
writeFileSync(path.join(destination, "export-manifest.json"), `${JSON.stringify({
  mode: "unsigned-mock-only",
  containsProductionData: false,
  files: manifest
}, null, 2)}\n`);
process.stdout.write(`Prepared ${manifest.length} allowlisted files and export-manifest.json at ${destination}\n`);
process.stdout.write("No repository created, commits made, files uploaded, or workflows executed.\n");
