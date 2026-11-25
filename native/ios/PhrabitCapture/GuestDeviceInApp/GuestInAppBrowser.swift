import Combine
import Foundation
import WebKit

@MainActor
final class GuestInAppBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    let webView: WKWebView
    private var page: URL?
    private var navigationResponseMatches = false
    private let proofWorld = WKContentWorld.world(name: "PhrabitDeviceCheck")

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func open(_ url: URL) {
        guard GuestInAppWebRequest.page(url.absoluteString) == url else { return }
        page = url
        navigationResponseMatches = false
        isReady = false
        isLoading = true
        failed = false
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        webView.load(request)
    }

    func send(_ route: GuestCheckJSONAPI.Route, _ data: Data, code: String) async throws -> GuestCheckJSONAPI.Reply {
        guard route == .challenge || route == .confirm, isReady, let page, webView.url == page,
              let pass = GuestInAppWebRequest.code(code), !data.isEmpty, data.count <= 35 * 1024,
              let body = String(data: data, encoding: .utf8) else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        try Task.checkCancellation()
        let value = try await webView.callAsyncJavaScript(
            GuestInAppWebRequest.confirmScript,
            arguments: ["expected": page.absoluteString, "path": route.rawValue, "body": body, "code": pass],
            in: nil, contentWorld: proofWorld
        )
        try Task.checkCancellation()
        guard isReady, webView.url == page, let result = value as? [String: Any],
              let status = result["status"] as? Int, (200...599).contains(status),
              let reply = result["body"] as? String, (1...2_048).contains(reply.utf8.count) else {
            throw GuestDeviceCheckError.unexpectedResponse
        }
        return .init(status: status, body: Data(reply.utf8))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url, page != nil else { return .cancel }
        return url == page || GuestInAppWebRequest.isVercelAuthNavigation(url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
              let url = response.url else { return .cancel }
        navigationResponseMatches = url == page && response.statusCode == 200 && response.mimeType == "text/html"
        return url == page || GuestInAppWebRequest.isVercelAuthNavigation(url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationResponseMatches = false
        isReady = false
        isLoading = true
        failed = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        isReady = navigationResponseMatches && webView.url == page
        failed = !isReady && webView.url == page
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleNavigationFailure()
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .deny
    }

    private func handleNavigationFailure() {
        navigationResponseMatches = false
        isReady = false
        isLoading = false
        failed = true
    }
}
