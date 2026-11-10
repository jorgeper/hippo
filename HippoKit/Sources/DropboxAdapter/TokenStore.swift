import Foundation
import Security
import os

public protocol TokenStore: Sendable {
    func load() throws -> DropboxTokens?
    func save(_ t: DropboxTokens) throws
    func clear() throws
}

public final class MemoryTokenStore: TokenStore {
    private let state = OSAllocatedUnfairLock<DropboxTokens?>(initialState: nil)
    public init(_ initial: DropboxTokens? = nil) { state.withLock { $0 = initial } }
    public func load() throws -> DropboxTokens? { state.withLock { $0 } }
    public func save(_ t: DropboxTokens) throws { state.withLock { $0 = t } }
    public func clear() throws { state.withLock { $0 = nil } }
}

/// JSON file, atomic write, 0600. Used for cross-process tests.
public struct FileTokenStore: TokenStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> DropboxTokens? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(DropboxTokens.self, from: data)
    }

    public func save(_ t: DropboxTokens) throws {
        let data = try JSONEncoder().encode(t)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let e as CocoaError where e.code == .fileNoSuchFile { }
    }
}

public struct KeychainTokenStore: TokenStore {
    public struct KeychainError: Error, Equatable { public let status: Int32 }

    public let service: String
    public let account: String
    public let accessGroup: String?

    public init(service: String = "com.jorgeper.hippo.dropbox", account: String = "tokens", accessGroup: String?) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func load() throws -> DropboxTokens? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(DropboxTokens.self, from: data)
    }

    public func save(_ t: DropboxTokens) throws {
        let data = try JSONEncoder().encode(t)
        let update = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// `"<team prefix>.<suffix>"`, learned by adding and reading a probe item; nil when that fails (off-device).
    public static func sharedAccessGroup(suffix: String = "com.jorgeper.hippo.shared") -> String? {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.jorgeper.hippo.probe",
                                    kSecAttrAccount as String: "probe"]
        var add = probe
        add[kSecValueData as String] = Data([0])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { status = errSecSuccess }
        guard status == errSecSuccess else { return nil }
        var q = probe
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first else { return nil }
        return "\(prefix).\(suffix)"
    }
}
