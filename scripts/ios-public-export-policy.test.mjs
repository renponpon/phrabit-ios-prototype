import assert from "node:assert/strict";
import test from "node:test";
import { assertPublicDocumentation } from "./ios-public-export-policy.mjs";

test("accepts technical identifiers and documentation links", () => {
  assert.doesNotThrow(() => assertPublicDocumentation("com.phrabit.app\nhttps://developer.apple.com/documentation/"));
});

test("rejects a synthetic contact address", () => {
  assert.throws(() => assertPublicDocumentation("Contact: person@example.invalid"));
});

test("rejects a private-key header without needing an actual key", () => {
  const marker = ["-----BEGIN", "PRIVATE KEY-----"].join(" ");
  assert.throws(() => assertPublicDocumentation(marker));
});

test("rejects personal enrollment log headings", () => {
  assert.throws(() => assertPublicDocumentation("## Apple登録の現在地"));
});

test("rejects a synthetic billing record", () => {
  assert.throws(() => assertPublicDocumentation("年間登録料: 12345円"));
});

test("accepts generic enrollment guidance without personal records", () => {
  assert.doesNotThrow(() => assertPublicDocumentation("加入条件や費用はApple公式ページで確認します。"));
});
