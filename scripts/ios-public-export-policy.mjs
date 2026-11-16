import assert from "node:assert/strict";

export function assertPublicDocumentation(contents) {
  assert.doesNotMatch(contents, /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i, "Keep contact addresses out of public prototype documentation");
  assert.doesNotMatch(contents, /-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----/, "Never export private signing material");
  assert.doesNotMatch(contents, /Apple登録の(?:現在地|確認経過)/, "Keep personal enrollment notes in local records");
  assert.doesNotMatch(contents, /(?:年間登録料|請求先|注文番号|メンバーシップ更新日)[^\n]*(?:\d{4}|[¥￥円])/, "Keep personal billing records out of public documentation");
}
