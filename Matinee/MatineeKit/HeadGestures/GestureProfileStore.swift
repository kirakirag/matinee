import CryptoKit
import Foundation
import Security

/// Where the key that seals the gesture profile lives.
public protocol GestureKeyStore: Sendable {
    /// The key; with `create`, made and stored when there is none yet.
    func key(create: Bool) throws -> SymmetricKey?
    func delete() throws
}

/// Keeps the `GestureProfile` on disk sealed with AES-256-GCM. How someone moves their head identifies them much as
/// a voice does, so the file alone (in a backup, a disk image, another process's hands) must tell nothing: the key
/// is kept apart from it, in the keychain. Resetting deletes both.
public struct GestureProfileStore: Sendable {
    private let file: URL
    private let keys: GestureKeyStore
    /// Bound into the seal, so a file from another format or purpose doesn't open.
    private static let context = Data("matinee-head-gestures-v1".utf8)

    public init(file: URL, keys: GestureKeyStore) {
        self.file = file
        self.keys = keys
    }

    /// The stored profile, or nil when there is none. A file that no longer opens (its key is gone, or it was
    /// changed) is deleted: there is nothing to recover from it. A keychain that can't be read right now (locked)
    /// deletes nothing.
    public func load() -> GestureProfile? {
        guard let sealed = try? Data(contentsOf: file) else { return nil }
        let key: SymmetricKey?
        do { key = try keys.key(create: false) } catch { return nil }
        guard let key,
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Self.context),
              let profile = try? JSONDecoder().decode(GestureProfile.self, from: plain) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return profile
    }

    public func save(_ profile: GestureProfile) throws {
        guard let key = try keys.key(create: true) else { throw CocoaError(.fileWriteNoPermission) }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(profile), using: key, authenticating: Self.context)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.combined!.write(to: file, options: .atomic)   // combined is nil only for a non-standard nonce
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = file
        try? url.setResourceValues(values)
    }

    /// Deletes the profile and its key.
    public func reset() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try keys.delete()
    }
}

/// The key as a generic password in the user's keychain: readable by Matinee only, never synced to iCloud.
public struct KeychainGestureKey: GestureKeyStore {
    private let service: String
    private static let account = "calibration-key"

    public init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account, kSecAttrSynchronizable as String: false]
    }

    public func key(create: Bool) throws -> SymmetricKey? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found)
        if status == errSecSuccess, let data = found as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        let add = query.merging([kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                 kSecAttrLabel as String: "Matinee head gesture calibration"]) { $1 }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
        return key
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
    }
}
