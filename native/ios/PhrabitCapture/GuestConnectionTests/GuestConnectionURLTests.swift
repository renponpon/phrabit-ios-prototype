import XCTest
@testable import PhrabitGuestConnection

final class GuestConnectionURLTests: XCTestCase {
    private let host = "phrabit-ios-guest-preview-012345678-renponpons-projects.vercel.app"
    private let status = "/api/ios/guest/status"

    func testAcceptsOnlyExactPreviewStatusLink() {
        let canonical = "https://\(host)\(status)"
        XCTAssertEqual(GuestConnectionURL.validated(" \n\(canonical)\n")?.absoluteString, canonical)
    }

    func testRejectsProductionAliasesAndOtherRoutes() {
        let candidates = [
            "https://phrabit.com\(status)",
            "https://phrabit-ios-guest-preview.vercel.app\(status)",
            "https://\(host)/api/ios/guest/capture",
            "https://\(host)\(status)/",
            "https://\(host)/api/ios/guest/%73tatus",
            "https://\(host)/../api/ios/guest/status"
        ]
        for candidate in candidates { XCTAssertNil(GuestConnectionURL.validated(candidate)) }
    }

    func testRejectsQueriesCredentialsPortsAndUntrustedOrigins() {
        let candidates = [
            "",
            "http://\(host)\(status)",
            "https://\(host):443\(status)",
            "https://\(host)@example.com\(status)",
            "https://\(host)\(status)?code=example",
            "https://\(host)\(status)#code",
            "https://\(host).example.com\(status)"
        ]
        for candidate in candidates { XCTAssertNil(GuestConnectionURL.validated(candidate)) }
    }
}
