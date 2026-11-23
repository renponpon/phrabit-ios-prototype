#if os(iOS)
import DeviceCheck
import Foundation
import Security

@MainActor
struct AppleGuestAttest: GuestAttestProvider {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ identifier: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(identifier, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ identifier: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(identifier, clientDataHash: clientDataHash)
    }
}

@MainActor
struct KeychainGuestAttestKeyStore: GuestAttestKeyStore {
    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.phrabit.app.guest-device-check.v1",
            kSecAttrAccount as String: "app-attest-key",
            kSecAttrSynchronizable as String: false
        ]
    }

    func read() throws -> GuestAttestKey? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = try? JSONDecoder().decode(GuestAttestKey.self, from: data) else {
            throw GuestDeviceCheckError.storageUnavailable
        }
        return key
    }

    func insert(_ key: GuestAttestKey) throws {
        var item = identity
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = try JSONEncoder().encode(key)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw GuestDeviceCheckError.storageUnavailable
        }
    }

    func replace(_ old: GuestAttestKey, with new: GuestAttestKey) throws {
        guard old.identifier == new.identifier, try read() == old else { throw GuestDeviceCheckError.storageUnavailable }
        let attributes = [kSecValueData as String: try JSONEncoder().encode(new)]
        guard SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecSuccess else {
            throw GuestDeviceCheckError.storageUnavailable
        }
    }
}
#endif
