import Foundation

enum GuestInAppWebRequest {
    static func page(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\Ahttps://phrabit-ios-guest-preview-[a-z0-9]{9,16}-renponpons-projects\.vercel\.app/api/ios/guest/device-test\z"#
        guard value.utf8.count <= 140, value.range(of: pattern, options: .regularExpression) != nil,
              let url = URL(string: value), url.absoluteString == value else { return nil }
        return url
    }

    static func code(_ text: String) -> String? {
        guard text.utf8.count <= 256 else { return nil }
        let value = text.replacingOccurrences(of: #"[\s\u200B\u2060]"#, with: "", options: .regularExpression)
        guard value.range(of: #"\A[0-9A-Fa-f]{64}\z"#, options: .regularExpression) != nil else { return nil }
        return value.lowercased()
    }

    static func isVercelAuthNavigation(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil else { return false }
        return parts.host == "vercel.com" || parts.host == "www.vercel.com"
    }

    static let confirmScript = #"""
    if (location.href !== expected || !document.getElementById("exchange")) throw new Error("page_not_ready");
    if (!["/api/ios/guest/challenge", "/api/ios/guest/device-check"].includes(path)) throw new Error("wrong_route");
    const encoder = new TextEncoder();
    if (typeof body !== "string" || !body.startsWith("{") || encoder.encode(body).length > 35 * 1024 ||
        typeof code !== "string" || !/^[0-9a-f]{64}$/.test(code)) throw new Error("invalid_input");
    const payload = JSON.parse(body);
    if (path.endsWith("/challenge") && payload?.purpose !== "device-check") throw new Error("wrong_purpose");
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8_000);
    try {
        const response = await fetch(path, {
            method: "POST", credentials: "same-origin", mode: "same-origin", cache: "no-store", redirect: "error",
            referrerPolicy: "no-referrer", headers: {
                "Content-Type": "application/json", Accept: "application/json", "x-phrabit-preview-pass": code
            }, body, signal: controller.signal
        });
        if (response.url !== new URL(path, expected).href || response.redirected || !response.body ||
            response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
            throw new Error("unexpected_response");
        }
        const reader = response.body.getReader();
        const decoder = new TextDecoder("utf-8", { fatal: true });
        let size = 0;
        let result = "";
        for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            size += value.byteLength;
            if (size > 2_048) {
                void reader.cancel().catch(() => {});
                throw new Error("oversized_response");
            }
            result += decoder.decode(value, { stream: true });
        }
        if (!size) throw new Error("empty_response");
        return { status: response.status, body: result + decoder.decode() };
    } finally {
        clearTimeout(timer);
    }
    """#
}
