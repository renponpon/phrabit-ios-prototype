import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PhrabitCaptureCore

@MainActor
final class CaptureHTTPProcessorTests: XCTestCase {
    private let identifier = UUID()

    func testTranslateSendsOnlyExplicitNonSavingFields() async throws {
        var requests = 0
        let sessionID = identifier
        CaptureStubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/capture/translate")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-session")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: String])
            XCTAssertEqual(Set(payload.keys), Set(["sessionId", "sourceText", "targetLanguage"]))
            return (200, try Self.translationResponse(sessionID, language: "zh"))
        }
        let processor = try makeProcessor()
        let result = try await processor.translate(text: "こんにちは", to: .chinese, sessionID: identifier)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(result.targetText, "你好")
        XCTAssertEqual(result.reading, "nǐ hǎo")
    }

    func testConsentDenialDoesNotRequestTokenOrUpload() async throws {
        var tokenRequests = 0
        var uploads = 0
        CaptureStubProtocol.handler = { _ in uploads += 1; return (500, Data()) }
        let processor = try CaptureHTTPProcessor(origin: URL(string: "https://preview.invalid")!, protocolClasses: [CaptureStubProtocol.self], consentGranted: { false }, accessToken: { tokenRequests += 1; return "test-session" })
        do {
            _ = try await processor.translate(text: "こんにちは", to: .english, sessionID: identifier)
            XCTFail("同意なしで送信しました")
        } catch { XCTAssertTrue(error is CaptureClientError) }
        XCTAssertEqual(tokenRequests, 0)
        XCTAssertEqual(uploads, 0)
    }

    func testFailedRequestIsNeverRetriedOrReplacedBySample() async throws {
        for status in [401, 429, 503, 504, 502] {
            var requests = 0
            CaptureStubProtocol.handler = { _ in requests += 1; return (status, Data("private-provider-message".utf8)) }
            do {
                _ = try await makeProcessor().translate(text: "こんにちは", to: .english, sessionID: identifier)
                XCTFail("エラーをサンプルへ置換しました")
            } catch {
                XCTAssertTrue(error is CaptureClientError)
                XCTAssertFalse(error.localizedDescription.contains("private-provider-message"))
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testWrongSessionOrLanguageResponseIsRejected() async throws {
        for wrongSession in [true, false] {
            let sessionID = wrongSession ? UUID() : identifier
            CaptureStubProtocol.handler = { _ in (200, try Self.translationResponse(sessionID, language: wrongSession ? "zh" : "en")) }
            do {
                _ = try await makeProcessor().translate(text: "こんにちは", to: .chinese, sessionID: identifier)
                XCTFail("違うセッション・言語の応答を表示しました")
            } catch { XCTAssertTrue(error is CaptureClientError) }
        }
    }

    func testEnglishHasNoPinyin() async throws {
        let sessionID = identifier
        CaptureStubProtocol.handler = { _ in (200, try Self.translationResponse(sessionID, language: "en")) }
        let result = try await makeProcessor().translate(text: "こんにちは", to: .english, sessionID: identifier)
        XCTAssertNil(result.reading)
        XCTAssertEqual(result.language, .english)
    }

    func testAudioUsesMultipartWithJapaneseServerContract() async throws {
        let sessionID = identifier
        CaptureStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/capture/transcribe")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Phrabit-") == true)
            let multipart = String(decoding: Self.body(of: request), as: UTF8.self)
            XCTAssertTrue(multipart.contains("name=\"audio\"; filename=\"recording.m4a\""))
            XCTAssertTrue(multipart.contains("name=\"durationMs\"\r\n\r\n1000"))
            XCTAssertFalse(multipart.contains("persist"))
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": sessionID.uuidString, "requestId": UUID().uuidString, "transcript": "こんにちは", "language": "ja"])
            return (200, data)
        }
        let text = try await makeProcessor().transcribe(audio: Data([1, 2, 3]), durationMilliseconds: 1000, sessionID: identifier)
        XCTAssertEqual(text, "こんにちは")
    }

    func testCancelledBeforeSendingDoesNotUpload() async throws {
        var requests = 0
        CaptureStubProtocol.handler = { _ in requests += 1; return (500, Data()) }
        let processor = try makeProcessor()
        let task = Task { try await processor.translate(text: "こんにちは", to: .english, sessionID: identifier) }
        task.cancel()
        do { _ = try await task.value; XCTFail("中断が無視されました") } catch is CancellationError {} catch { XCTFail("取消ではないエラー") }
        XCTAssertEqual(requests, 0)
    }

    func testUnsafeOriginsAreRejected() {
        for value in ["http://preview.invalid", "https://user:secret@preview.invalid", "https://preview.invalid/other", "https://preview.invalid?token=value"] {
            XCTAssertThrowsError(try CaptureHTTPProcessor(origin: URL(string: value)!, consentGranted: { true }, accessToken: { "test-session" }))
        }
    }

    private func makeProcessor() throws -> CaptureHTTPProcessor {
        try CaptureHTTPProcessor(origin: URL(string: "https://preview.invalid")!, protocolClasses: [CaptureStubProtocol.self], consentGranted: { true }, accessToken: { "test-session" })
    }

    nonisolated private static func translationResponse(_ sessionID: UUID, language: String) throws -> Data {
        var result: [String: Any] = ["sessionId": sessionID.uuidString, "requestId": UUID().uuidString, "sourceText": "こんにちは", "targetText": language == "zh" ? "你好" : "Hello", "targetLanguage": language]
        if language == "zh" { result["reading"] = "nǐ hǎo"; result["readingType"] = "pinyin" }
        return try JSONSerialization.data(withJSONObject: result)
    }

    nonisolated private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}

private final class CaptureStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
