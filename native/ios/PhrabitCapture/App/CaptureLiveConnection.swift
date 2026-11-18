import PhrabitCaptureCore

@MainActor
struct CaptureLiveConnection {
    let access: CaptureAccessController
    let capture: CaptureViewModel
    let diagnostics: CaptureConnectionDiagnostics

    init(configuration: CaptureAuthConfiguration) throws {
        let browser = CaptureBrowserLogin()
        let storage = CaptureCredentialStore()
        let backend = CaptureSupabaseAuthentication(configuration: configuration, storage: storage, openBrowser: { try await browser.open($0) })
        let access = CaptureAccessController(backend: backend, storage: storage, environmentID: configuration.environmentID)
        let processor = try CaptureHTTPProcessor(origin: configuration.apiOrigin, consentGranted: { access.canRecord }, accessToken: { try await access.validAccessToken() })
        self.access = access
        self.capture = CaptureViewModel(processor: processor, recordingAllowed: { access.canRecord }, authenticationRequired: { access.clearSession() })
        let verifier = try CaptureConnectionVerifier(origin: configuration.apiOrigin, access: access)
        self.diagnostics = CaptureConnectionDiagnostics(access: access, check: { try await verifier.verify() })
    }
}
