import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { runInNewContext } from "node:vm";

const base = new URL("../native/ios/PhrabitCapture/", import.meta.url);
const swift = file => readFileSync(new URL("GuestDeviceInApp/" + file, base), "utf8");
const requestSource = swift("GuestInAppWebRequest.swift");
const script = requestSource.split('#"""')[1].split('"""#')[0];
const confirmPath = "/api/ios/guest/device-check";
const challengePath = "/api/ios/guest/challenge";
const preview = "https://phrabit-ios-guest-preview-000000000-renponpons-projects.vercel.app/api/ios/guest/device-test";
const code = "0".repeat(64);

function run({ path = confirmPath, body = "{}", location = preview, marker = true, pass = code,
  reply = '{"status":"verified"}', status = 200, contentType = "application/json", redirected = false,
  replyURL = new URL(path, preview).href, networkError = false, onRequest = () => {} } = {}) {
  return runInNewContext("(async () => {" + script + "})()", {
    expected: preview, path, body, location: { href: location }, code: pass,
    document: { getElementById: () => marker ? {} : null },
    AbortController, TextEncoder, TextDecoder, URL, setTimeout, clearTimeout,
    fetch: async (url, options) => {
      onRequest(url, options);
      if (networkError) throw new Error("network_error");
      const response = new Response(reply, { status, headers: { "content-type": contentType } });
      Object.defineProperties(response, { url: { value: replyURL }, redirected: { value: redirected } });
      return response;
    },
  });
}

test("only same-origin JSON POST carries the code and fresh proof; no persistence or redirects", async () => {
  const body = '{"proof":"test"}';
  let calls = 0;
  const result = await run({ body, onRequest(url, options) {
    calls++;
    assert.equal(url, confirmPath);
    assert.equal(options.body, body);
    assert.equal(options.headers["Content-Type"], "application/json");
    assert.equal(options.headers["x-phrabit-preview-pass"], code);
    assert.equal(options.method, "POST");
    assert.equal(options.credentials, "same-origin");
    assert.equal(options.mode, "same-origin");
    assert.equal(options.cache, "no-store");
    assert.equal(options.redirect, "error");
    assert.equal(options.referrerPolicy, "no-referrer");
    assert.ok(options.signal instanceof AbortSignal);
  } });
  assert.equal(calls, 1);
  assert.equal(result.status, 200);
  assert.equal(JSON.parse(result.body).status, "verified");
});

test("the exact signed-in page and form marker are required before any request", async () => {
  for (const options of [
    { location: "https://vercel.com/login" },
    { location: preview + "?added=1" },
    { location: preview.replace(".vercel.app", ".example.test") },
    { marker: false },
  ]) {
    await assert.rejects(run({ ...options, onRequest: () => assert.fail("must not send") }), /page_not_ready/);
  }
});

test("only a device-check challenge and proof are sent, never registration or audio", async () => {
  const result = await run({ path: challengePath, body: '{"purpose":"device-check"}',
    reply: '{"challengeId":"example"}', onRequest: url => assert.equal(url, challengePath) });
  assert.equal(JSON.parse(result.body).challengeId, "example");
  for (const path of ["/api/ios/guest/register", "/api/ios/guest/capture", "//example.test/send"]) {
    await assert.rejects(run({ path, onRequest: () => assert.fail("must not send") }), /wrong_route/);
  }
  for (const purpose of ["register", "capture"]) {
    await assert.rejects(run({ path: challengePath, body: JSON.stringify({ purpose }),
      onRequest: () => assert.fail("must not send") }), /wrong_purpose/);
  }
});

test("bad code and oversized input fail before sending", async () => {
  for (const options of [{ pass: "short" }, { body: '{"proof":"' + "q".repeat(35 * 1024) + '"}' }]) {
    await assert.rejects(run({ ...options, onRequest: () => assert.fail("must not send") }), /invalid_input/);
  }
});

test("rejects a login page, redirected response, other origin and oversize output", async () => {
  for (const options of [
    { contentType: "text/html" }, { redirected: true }, { replyURL: "https://example.test/"},
  ]) {
    await assert.rejects(run(options), /unexpected_response/);
  }
  await assert.rejects(run({ reply: "a".repeat(2_049) }), /oversized_response/);
  await assert.rejects(run({ reply: "" }), /empty_response/);
});

test("passes application errors to the flow without success or retry", async () => {
  const result = await run({ status: 401, reply: '{"code":"unverified"}' });
  assert.equal(result.status, 401);
  assert.equal(JSON.parse(result.body).code, "unverified");
  let calls = 0;
  await assert.rejects(run({ networkError: true, onRequest: () => calls++ }), /network_error/);
  assert.equal(calls, 1);
});

test("the new target is unsigned, separate, and has no recorder, clipboard or login cookies in native storage", () => {
  const spec = readFileSync(new URL("guest-device-in-app.yml", base), "utf8");
  assert.match(spec, /CODE_SIGNING_ALLOWED: "NO"/);
  assert.match(spec, /PRODUCT_BUNDLE_IDENTIFIER: com\.phrabit\.app\.guestdeviceinapp/);
  assert.doesNotMatch(spec, /GuestDeviceProbe|GuestCheckPreviewTransport|entitlements|NSMicrophone|CFBundleURLTypes/);
  const view = swift("PhrabitGuestDeviceInApp.swift");
  assert.match(view, /\.phase == \.registered/);
  assert.match(view, /try await flow\.confirm\(\)/);
  assert.doesNotMatch(view, /UIPasteboard|PasteButton|import AVFoundation|flow\.enroll|flow\.prepare/);
  const transport = swift("GuestInAppBrowser.swift");
  assert.match(transport, /websiteDataStore = \.nonPersistent\(\)/);
  assert.match(transport, /requestMediaCapturePermissionFor[\s\S]+?\.deny/);
  assert.doesNotMatch(transport, /HTTPCookie|httpCookieStore|URLSession|x-vercel-protection-bypass|UserDefaults/);
});
