import Foundation
import CryptoKit
import PhrabitCaptureCore
import Security

struct CaptureCredentialStore: CaptureSecureStorage {
    private let service = "com.phrabit.app.auth"
    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CaptureClientStorageError.unavailable }
        return data
    }

    func store(key: String, value: Data) throws {
        guard !value.isEmpty, value.count <= 65_536 else { throw CaptureClientStorageError.unavailable }
        let attributes: [String: Any] = [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(baseQuery(key: key) as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = baseQuery(key: key)
            item.merge(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CaptureClientStorageError.unavailable }
        } else if update != errSecSuccess { throw CaptureClientStorageError.unavailable }
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CaptureClientStorageError.unavailable }
    }

    private func baseQuery(key: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}

enum CaptureClientStorageError: LocalizedError {
    case unavailable
    var errorDescription: String? { "ログイン情報を安全に保存できませんでした。" }
}
