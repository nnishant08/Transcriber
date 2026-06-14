import Foundation
import CryptoKit
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Feature C4 — the single seam ALL session-folder file I/O goes through. When encryption is OFF
/// (the default) it is **byte-identical passthrough** — existing files, existing bytes, existing
/// behavior. When ON, artifacts are AES-GCM encrypted at rest with a per-install key in the Keychain
/// (optionally gated by Touch ID at app unlock); reads decrypt transparently.
///
/// Robustness: an encrypted blob carries a `TRENC1` magic prefix, so `readData` decrypts iff the
/// bytes are actually encrypted (and a key is available) — reads keep working mid-migration or after
/// a toggle, regardless of the global flag. This means turning encryption off doesn't break access to
/// files not yet re-written as plaintext.
enum SessionIOError: LocalizedError {
    case noKey, verifyFailed(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No encryption key is available."
        case .verifyFailed(let m): return "Encryption migration verify failed: \(m)"
        }
    }
}

enum SessionIO {

    /// Magic prefix marking an encrypted blob (`TRENC1`).
    private static let magic = Data([0x54, 0x52, 0x45, 0x4E, 0x43, 0x31])

    // MARK: Flags (persisted) + test hooks

    static var isEncryptionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "encryptionEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "encryptionEnabled") }
    }
    static var requireTouchID: Bool {
        get { UserDefaults.standard.bool(forKey: "encryptionRequireTouchID") }
        set { UserDefaults.standard.set(newValue, forKey: "encryptionRequireTouchID") }
    }
    /// Tests inject a fixed key so the keychain/biometry are never touched headlessly.
    static var overrideKey: SymmetricKey?

    // MARK: Seam (every session-folder read/write routes here)

    /// Read a file's logical bytes — decrypting transparently when the on-disk blob is encrypted and
    /// a key is available. Plaintext files always pass through unchanged.
    static func readData(_ url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        return decryptIfNeeded(raw)
    }

    /// Write logical bytes — encrypting when encryption is enabled and a key is available, else a raw
    /// (byte-identical) write. Atomic so a concurrent reader never sees a torn file.
    static func writeData(_ data: Data, to url: URL) throws {
        if isEncryptionEnabled, let key = currentKey() {
            try encrypt(data, key: key).write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? readData(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func writeText(_ s: String, to url: URL) throws { try writeData(Data(s.utf8), to: url) }

    static func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Crypto

    static func isEncryptedBlob(_ data: Data) -> Bool { data.count > magic.count && data.prefix(magic.count) == magic }

    static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw SessionIOError.verifyFailed("seal produced no combined box") }
        return magic + combined
    }

    static func decrypt(_ blob: Data, key: SymmetricKey) throws -> Data {
        let body = blob.dropFirst(magic.count)
        let box = try AES.GCM.SealedBox(combined: body)
        return try AES.GCM.open(box, using: key)
    }

    /// Decrypt if the bytes are an encrypted blob and a key is available; otherwise return as-is.
    static func decryptIfNeeded(_ data: Data) -> Data {
        guard isEncryptedBlob(data), let key = currentKey(), let plain = try? decrypt(data, key: key) else { return data }
        return plain
    }

    static func currentKey() -> SymmetricKey? { overrideKey ?? loadOrCreateKeychainKey() }

    // MARK: Keychain key

    private static let keyService = "com.nikhil.transcriber.encryption"
    private static let keyAccount = "session-key"

    /// Load the per-install key, creating + storing one on first use. Returns nil only if the Keychain
    /// is genuinely unavailable (then encryption can't be enabled — surfaced as an error, never silent
    /// plaintext exposure).
    static func loadOrCreateKeychainKey() -> SymmetricKey? {
        if let existing = readKeychainKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        return storeKeychainKey(key) ? key : nil
    }

    private static func readKeychainKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    @discardableResult
    private static func storeKeychainKey(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService, kSecAttrAccount as String: keyAccount,
        ]
        SecItemDelete(delete as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService, kSecAttrAccount as String: keyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Touch ID (optional app-unlock gate)

    /// Prompt for Touch ID when `requireTouchID` is on. Returns true if not required, or on success.
    /// A failure returns false so the caller can keep data locked — never silently exposes plaintext.
    @discardableResult
    static func authenticateIfNeeded(reason: String = "Unlock your encrypted transcripts") async -> Bool {
        guard isEncryptionEnabled, requireTouchID else { return true }
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return false }
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, _ in cont.resume(returning: ok) }
        }
        #else
        return true
        #endif
    }

    // MARK: Migration (enable / disable) — copy-then-verify-then-replace + one-time backup

    /// File names within a session folder that hold user content (text + media).
    private static func contentFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for name in ["transcript.md", "session.json", "transcript.redacted.md", "audio.m4a", "audio.caf"] {
            let u = dir.appendingPathComponent(name); if fm.fileExists(atPath: u.path) { urls.append(u) }
        }
        // source.* (imported originals) + every image.
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            urls += entries.filter { $0.lastPathComponent.hasPrefix("source.") }
        }
        let images = dir.appendingPathComponent("images")
        if let imgs = try? fm.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) {
            urls += imgs.filter { $0.pathExtension.lowercased() == "png" }
        }
        return urls
    }

    /// Encrypt every session's content in place (idempotent: already-encrypted files are skipped),
    /// after one full backup of the Transcripts directory. Throws on key/verify failure (no data lost
    /// — the original is replaced only after the encrypted copy round-trips back to identical bytes).
    static func enableEncryption(root: URL = SessionStore.root, backup: Bool = true) throws {
        guard let key = currentKey() else { throw SessionIOError.noKey }
        if backup { try backupRoot(root) }
        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            for url in contentFiles(in: dir) {
                let raw = try Data(contentsOf: url)
                if isEncryptedBlob(raw) { continue }
                let enc = try encrypt(raw, key: key)
                try replace(url, with: enc, verifyPlain: raw, key: key)
            }
        }
        isEncryptionEnabled = true
    }

    /// Decrypt every session's content back to plaintext (idempotent), then clear the flag.
    static func disableEncryption(root: URL = SessionStore.root) throws {
        guard let key = currentKey() else { throw SessionIOError.noKey }
        for dir in SessionStore.sessionDirectoryURLs(root: root) {
            for url in contentFiles(in: dir) {
                let raw = try Data(contentsOf: url)
                guard isEncryptedBlob(raw) else { continue }
                let plain = try decrypt(raw, key: key)
                try plain.write(to: url, options: .atomic)
            }
        }
        isEncryptionEnabled = false
    }

    /// Write `newData` to `url` atomically, then verify a fresh read decrypts back to `verifyPlain`
    /// BEFORE the write is considered durable (copy-then-verify-then-replace via .atomic + read-back).
    private static func replace(_ url: URL, with newData: Data, verifyPlain: Data, key: SymmetricKey) throws {
        let tmp = url.appendingPathExtension("trenc-tmp")
        try newData.write(to: tmp, options: .atomic)
        let readback = try Data(contentsOf: tmp)
        guard isEncryptedBlob(readback), (try? decrypt(readback, key: key)) == verifyPlain else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionIOError.verifyFailed(url.lastPathComponent)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    private static func backupRoot(_ root: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let backup = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)_preencrypt_\(SessionStore.backupStamp.string(from: Date()))")
        try fm.copyItem(at: root, to: backup)
        NSLog("[Encrypt] backed up Transcripts to \(backup.path)")
    }
}
