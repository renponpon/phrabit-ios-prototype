import Foundation

enum GuestConnectionURL {
    static func validated(_ input: String) -> URL? {
        let address = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\Ahttps://phrabit-ios-guest-preview-[a-z0-9]{9,16}-renponpons-projects\.vercel\.app/api/ios/guest/status\z"#
        guard address.utf8.count <= 140,
              address.range(of: pattern, options: .regularExpression) != nil,
              let url = URL(string: address), url.absoluteString == address else {
            return nil
        }
        return url
    }
}
