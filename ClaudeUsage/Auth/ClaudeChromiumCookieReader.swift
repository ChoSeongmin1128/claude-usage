import Foundation
import CommonCrypto
import Security
import SQLite3

struct ClaudeChromiumCookieRecord: Sendable, Equatable {
    let domain: String
    let name: String
    let path: String
    let value: String
    let expiresAt: Date?
    let isSecure: Bool
}

enum ClaudeChromiumCookieReaderError: LocalizedError, Sendable {
    case unableToCopyCookies(details: String)
    case sqliteOpenFailed(details: String)
    case sqlitePrepareFailed(details: String)

    var errorDescription: String? {
        switch self {
        case .unableToCopyCookies(let details):
            return "Cookies DB 복사 실패: \(details)"
        case .sqliteOpenFailed(let details):
            return "Cookies DB 열기 실패: \(details)"
        case .sqlitePrepareFailed(let details):
            return "Cookies DB 쿼리 준비 실패: \(details)"
        }
    }
}

enum ClaudeChromiumCookieReader {
    nonisolated static func readCookies(
        cookiesURL sourceURL: URL,
        profileName: String,
        localStateURL: URL?) throws -> [ClaudeChromiumCookieRecord]
    {
        let tempDirectory = try self.makeTemporaryDirectory(
            prefix: "claude-chromium-\(profileName.replacingOccurrences(of: " ", with: "_"))")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let copiedDB = tempDirectory.appendingPathComponent("Cookies", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: copiedDB)
            self.copyIfExists(URL(fileURLWithPath: sourceURL.path + "-wal"), to: URL(fileURLWithPath: copiedDB.path + "-wal"))
            self.copyIfExists(URL(fileURLWithPath: sourceURL.path + "-shm"), to: URL(fileURLWithPath: copiedDB.path + "-shm"))
        } catch {
            throw ClaudeChromiumCookieReaderError.unableToCopyCookies(details: error.localizedDescription)
        }

        let encryptedKeys = self.chromeCookieKeys(localStateURL: localStateURL)
        return try self.readCookies(fromCopiedDatabase: copiedDB, keys: encryptedKeys)
    }

    private nonisolated static func readCookies(fromCopiedDatabase databaseURL: URL, keys: [Data]) throws -> [ClaudeChromiumCookieRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ClaudeChromiumCookieReaderError.sqliteOpenFailed(details: self.sqliteErrorMessage(database))
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT host_key, name, path, expires_utc, is_secure, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE '%claude.ai%' OR host_key LIKE '%anthropic.com%'
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClaudeChromiumCookieReaderError.sqlitePrepareFailed(details: self.sqliteErrorMessage(database))
        }
        defer { sqlite3_finalize(statement) }

        var records: [ClaudeChromiumCookieRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hostKey = self.columnText(statement, index: 0),
                  let name = self.columnText(statement, index: 1),
                  let path = self.columnText(statement, index: 2) else {
                continue
            }

            let plainValue = self.columnText(statement, index: 5)
            let encryptedValue = self.columnBlob(statement, index: 6)
            let resolvedValue = self.resolveValue(plainValue: plainValue, encryptedValue: encryptedValue, keys: keys)
            guard let resolvedValue, !resolvedValue.isEmpty else { continue }

            records.append(ClaudeChromiumCookieRecord(
                domain: self.normalizeDomain(hostKey),
                name: name,
                path: path,
                value: resolvedValue,
                expiresAt: self.chromiumExpiry(sqlite3_column_int64(statement, 3)),
                isSecure: sqlite3_column_int(statement, 4) != 0))
        }

        return records.filter { record in
            guard let expiresAt = record.expiresAt else { return true }
            return expiresAt >= Date()
        }
    }

    private nonisolated static func chromeCookieKeys(localStateURL: URL?) -> [Data] {
        var keys: [Data] = []
        let labels = [
            ("Chrome Safe Storage", "Chrome"),
            ("Chromium Safe Storage", "Chromium"),
            ("Google Chrome Safe Storage", "Chrome"),
        ]

        for (service, account) in labels {
            if let password = self.safeStoragePassword(service: service, account: account) {
                keys.append(self.deriveKey(from: password))
            }
        }

        if !keys.isEmpty {
            return keys
        }

        if let localStateURL,
           let encryptedKey = self.encryptedKey(from: localStateURL),
           let plainKey = self.decryptLocalStateKey(encryptedKey: encryptedKey) {
            keys.append(plainKey)
        }

        return keys
    }

    private nonisolated static func safeStoragePassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func encryptedKey(from localStateURL: URL) -> Data? {
        guard let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let osCrypt = json["os_crypt"] as? [String: Any],
              let encryptedKey = osCrypt["encrypted_key"] as? String,
              let decoded = Data(base64Encoded: encryptedKey) else {
            return nil
        }
        return decoded
    }

    private nonisolated static func decryptLocalStateKey(encryptedKey: Data) -> Data? {
        guard encryptedKey.count > 5 else { return nil }
        let payload = encryptedKey.starts(with: Data("DPAPI".utf8))
            ? encryptedKey.dropFirst(5)
            : encryptedKey
        return Data(payload)
    }

    private nonisolated static func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyBytes.count)
                }
            }
        }
        return key
    }

    private nonisolated static func resolveValue(plainValue: String?, encryptedValue: Data?, keys: [Data]) -> String? {
        if let plainValue, !plainValue.isEmpty {
            return plainValue
        }

        guard let encryptedValue, !encryptedValue.isEmpty else { return nil }
        return self.decrypt(encryptedValue, usingAnyOf: keys)
    }

    private nonisolated static func decrypt(_ encryptedValue: Data, usingAnyOf keys: [Data]) -> String? {
        for key in keys {
            if let value = self.decrypt(encryptedValue, key: key) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func decrypt(_ encryptedValue: Data, key: Data) -> String? {
        guard encryptedValue.count > 3 else { return nil }
        guard let prefix = String(data: encryptedValue.prefix(3), encoding: .utf8),
              prefix == "v10" || prefix == "v11" else {
            return nil
        }

        let payload = Data(encryptedValue.dropFirst(3))
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outLength = 0

        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength..<out.count)

        if let value = String(data: out, encoding: .utf8), self.looksReasonableCookieValue(value) {
            return value
        }

        if out.count > 32 {
            let trimmed = out.dropFirst(32)
            if let value = String(data: trimmed, encoding: .utf8), self.looksReasonableCookieValue(value) {
                return value
            }
        }

        return nil
    }

    private nonisolated static func chromiumExpiry(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let microsecondsSinceUnixEpoch = value - 11_644_473_600_000_000
        guard microsecondsSinceUnixEpoch > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(microsecondsSinceUnixEpoch) / 1_000_000)
    }

    private nonisolated static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func copyIfExists(_ source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private nonisolated static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(cString).assumingMemoryBound(to: CChar.self))
    }

    private nonisolated static func columnBlob(_ statement: OpaquePointer?, index: Int32) -> Data? {
        let bytes = sqlite3_column_blob(statement, index)
        let length = sqlite3_column_bytes(statement, index)
        guard let bytes, length > 0 else { return nil }
        return Data(bytes: bytes, count: Int(length))
    }

    private nonisolated static func normalizeDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
    }

    private nonisolated static func looksReasonableCookieValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        guard trimmed.count >= 16, trimmed.count <= 2048 else { return false }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        return !hasControl
    }

    private nonisolated static func sqliteErrorMessage(_ database: OpaquePointer?) -> String {
        guard let database else { return "unknown" }
        return String(cString: sqlite3_errmsg(database))
    }
}
