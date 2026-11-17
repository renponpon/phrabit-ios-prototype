import Foundation
import Security

struct CaptureCredentialStore {
    private let service = "com.phrabit.app.auth"
    private let account = "session"

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CaptureClientStorageError.unavailable }
        return data
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw CaptureClientStorageError.unavailable }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = baseQuery
            item.merge(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CaptureClientStorageError.unavailable }
        } else if update != errSecSuccess { throw CaptureClientStorageError.unavailable }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CaptureClientStorageError.unavailable }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}

enum CaptureClientStorageError: LocalizedError {
    case unavailable
    var errorDescription: String? { "ログイン情報を安全に保存できませんでした。" }
}
