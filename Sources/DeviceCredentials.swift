import Foundation
import Security

struct DeviceCredentials: Codable, Sendable {
    var token = ""
    var password = ""
    var multiUser = false
}

enum CredentialStore {
    static func load(_ endpoint: Endpoint) -> DeviceCredentials? {
        LocalKeychain.load(service: "com.turbo.ufi.device", account: endpoint.address)
    }

    static func save(_ credentials: DeviceCredentials, for endpoint: Endpoint) -> Bool {
        LocalKeychain.save(credentials, service: "com.turbo.ufi.device", account: endpoint.address)
    }

    @discardableResult
    static func forget(_ endpoint: Endpoint) -> Bool {
        LocalKeychain.forget(service: "com.turbo.ufi.device", account: endpoint.address)
    }
}

enum LocalKeychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func load<Value: Decodable>(service: String, account: String) -> Value? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &data) == errSecSuccess,
              let value = data as? Data else { return nil }
        return try? JSONDecoder().decode(Value.self, from: value)
    }

    static func save<Value: Encodable>(_ value: Value, service: String, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let request = query(service: service, account: account)
        let fields: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(request as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var entry = request
        entry[kSecValueData as String] = data
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(entry as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func forget(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
