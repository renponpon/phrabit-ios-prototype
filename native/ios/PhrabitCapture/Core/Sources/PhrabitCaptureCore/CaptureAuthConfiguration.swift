import Foundation

public struct CaptureAuthConfiguration: Sendable {
    public let apiOrigin: URL
    public let projectURL: URL
    public let publishableKey: String
    public static let callbackURL = URL(string: "com.phrabit.app://auth/callback")!
    public var environmentID: String { projectURL.absoluteString + "|" + apiOrigin.absoluteString }

    public init(apiOrigin: URL, projectURL: URL, publishableKey: String) throws {
        for origin in [apiOrigin, projectURL] {
            guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
                  origin.query == nil, origin.fragment == nil, origin.path.isEmpty || origin.path == "/" else { throw CaptureAccessError.configuration }
        }
        guard !publishableKey.isEmpty, publishableKey.count <= 4096, !publishableKey.contains(where: { $0.isWhitespace }) else { throw CaptureAccessError.configuration }
        if !publishableKey.hasPrefix("sb_publishable_") {
            let components = publishableKey.split(separator: ".")
            guard components.count == 3 else { throw CaptureAccessError.configuration }
            var payload = String(components[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let data = Data(base64Encoded: payload), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["role"] as? String == "anon" else { throw CaptureAccessError.configuration }
        }
        self.apiOrigin = apiOrigin
        self.projectURL = projectURL
        self.publishableKey = publishableKey
    }

    public static func authorizationCode(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == callbackURL.scheme,
              parts.host == callbackURL.host, parts.path == callbackURL.path, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let items = parts.queryItems, items.count == 1,
              items[0].name == "code", let code = items[0].value, !code.isEmpty, code.count <= 2048,
              !code.contains(where: { $0.isWhitespace }) else { throw CaptureAccessError.callback }
        return code
    }
}
