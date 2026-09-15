//
//  CodexAuthManager.swift
//  ClaudeUsage
//
//  Codex (ChatGPT) 인증 관리 — ~/.codex/auth.json (OAuth, codex login)
//  참고: https://github.com/steipete/CodexBar
//

import CryptoKit
import Darwin
import Foundation
import os

/// Codex 인증 토큰
nonisolated struct CodexAuthToken: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?
    let lastRefresh: Date?
    let expiresAt: Date?
    /// `tokens.expires_at` 또는 access JWT `exp` 처럼 토큰 자체에서 신뢰 가능한 만료 시각을 읽었는지.
    /// 없으면 `last_refresh + N일` 같은 휴리스틱은 가정만이므로 만료 판단을 보류한다.
    /// 사용 패턴: 실제 401 받았을 때만 refresh 시도, 그 외에는 access_token 그대로 사용.
    let expiresAtIsExplicit: Bool

    nonisolated init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        lastRefresh: Date? = nil,
        expiresAt: Date? = nil,
        expiresAtIsExplicit: Bool = false
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.lastRefresh = lastRefresh
        self.expiresAt = expiresAt
        self.expiresAtIsExplicit = expiresAtIsExplicit
    }

    nonisolated var isExpired: Bool {
        // [A] 보수화: 토큰 자체에서 만료 시각을 확인했을 때만 그 시각 기준으로 만료 판단.
        // 토큰 근거가 없으면 우리가 추측(last_refresh + 8일)으로 만료를 단정짓지 않는다.
        // 이유: ChatGPT OAuth access_token 의 실제 수명은 last_refresh 기준 휴리스틱과
        // 다를 수 있고, 사용자의 CLI 가 같은 토큰을 잘 쓰는 한 우리도 그대로 써야 안전하다.
        // 진짜 만료(401) 는 API 호출 시점에 판단한다.
        guard let expiresAt, expiresAtIsExplicit else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300) // 5분 전부터 만료 취급
    }

    nonisolated var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return !refreshToken.isEmpty
    }

    nonisolated var isUsableOrRefreshable: Bool {
        !isExpired || hasRefreshToken
    }
}

private nonisolated struct CodexAuthJSONStore: Sendable {
    static func decode(_ data: Data) -> CodexAuthToken? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Codex CLI 형식: { "tokens": { "access_token": "...", "refresh_token": "...", ... }, "last_refresh": "..." }
        // 레거시 형식: { "access_token": "...", "refresh_token": "..." }
        let tokens: [String: Any]
        if let nested = json["tokens"] as? [String: Any] {
            tokens = nested
        } else {
            tokens = json
        }

        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                return CodexAuthToken(accessToken: apiKey, refreshToken: nil, expiresAt: nil)
            }
            return nil
        }

        let refreshToken = tokens["refresh_token"] as? String
        let idToken = tokens["id_token"] as? String
        let accountID = (tokens["account_id"] as? String) ?? (json["account_id"] as? String)
        let lastRefresh = Self.parseISODate(json["last_refresh"] as? String)

        // 1순위: auth.json 이 명시한 expires_at.
        // 2순위: access_token 이 JWT 인 경우 payload.exp.
        // 둘 다 없으면 last_refresh 기반 만료 추정은 하지 않는다.
        let explicitExpiresAt = Self.parseExpiresAt(tokens["expires_at"]) ?? Self.jwtExpirationDate(from: accessToken)

        return CodexAuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            lastRefresh: lastRefresh,
            expiresAt: explicitExpiresAt,
            expiresAtIsExplicit: explicitExpiresAt != nil)
    }

    private static func parseExpiresAt(_ rawValue: Any?) -> Date? {
        if let expiresAtStr = rawValue as? String {
            return parseISODate(expiresAtStr)
        }
        if let expiresAtTimestamp = rawValue as? Double {
            return Date(timeIntervalSince1970: expiresAtTimestamp)
        }
        if let expiresAtTimestamp = rawValue as? Int {
            return Date(timeIntervalSince1970: TimeInterval(expiresAtTimestamp))
        }
        return nil
    }

    private static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func jwtExpirationDate(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecode(String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        if let exp = payload["exp"] as? Double {
            return Date(timeIntervalSince1970: exp)
        }
        if let exp = payload["exp"] as? Int {
            return Date(timeIntervalSince1970: TimeInterval(exp))
        }
        return nil
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        return Data(base64Encoded: base64)
    }
}

nonisolated struct CodexCredentialSnapshot: Sendable {
    let token: CodexAuthToken
    let generation: UUID
    let sourceURL: URL
}

nonisolated enum CodexCredentialError: Error, Equatable {
    case missing
    case unreadable
    case malformed
    case changed
}

/// The CLI owns auth.json. ClaudeUsage only reads it, including during recovery.
/// Background inspections are serialized. The separate presentation lock is
/// never held during file I/O, and invalidation prevents late cache publication.
nonisolated final class CodexAuthManager: @unchecked Sendable {
    static let shared = CodexAuthManager(authJsonPath: defaultAuthJsonPath())
    private let sourceURL: URL
    private let inspection = NSLock()
    private let cache = OSAllocatedUnfairLock(initialState: CacheState())

    private struct CacheState {
        var epoch = 0
        var digest: Data?
        var snapshot: CodexCredentialSnapshot?
        var fileExists = false
    }

    init(authJsonPath: String) {
        sourceURL = URL(fileURLWithPath: authJsonPath)
        if sourceURL.path == Self.defaultAuthJsonPath() {
            UserDefaults.standard.removeObject(forKey: "codex-auth-token")
            UserDefaults.standard.removeObject(forKey: "codex-device-id")
        }
        // Populate initial presentation once. Subsequent UI reads never touch disk.
        _ = try? reload()
    }

    static func defaultAuthJsonPath() -> String {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json").path
    }

    func getToken() -> CodexAuthToken? { cachedSnapshot?.token }
    var cachedSnapshot: CodexCredentialSnapshot? { cache.withLock { $0.snapshot } }
    var authJsonExists: Bool { cache.withLock { $0.fileExists } }
    var isAuthenticated: Bool { getToken()?.isUsableOrRefreshable == true }

    func clearCache() {
        cache.withLock { $0 = CacheState(epoch: $0.epoch + 1) }
    }

    func loadSnapshot() async throws -> CodexCredentialSnapshot {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) { try self.reload() }.value
        try Task.checkCancellation()
        return result
    }

    func validate(_ snapshot: CodexCredentialSnapshot) async throws {
        guard try await loadSnapshot().generation == snapshot.generation else {
            throw CodexCredentialError.changed
        }
    }

    private func reload() throws -> CodexCredentialSnapshot {
        try inspection.withLock {
            let epoch = cache.withLock { $0.epoch }
            do {
                let data = try readStableFile()
                let digest = Data(SHA256.hash(data: data))
                if let existing = cache.withLock({ state in
                    state.epoch == epoch && state.digest == digest ? state.snapshot : nil
                }) {
                    return existing
                }
                guard let token = CodexAuthJSONStore.decode(data) else { throw CodexCredentialError.malformed }
                return try cache.withLock { state in
                    guard state.epoch == epoch else { throw CodexCredentialError.changed }
                    let snapshot = CodexCredentialSnapshot(token: token, generation: UUID(), sourceURL: sourceURL)
                    state.digest = digest
                    state.snapshot = snapshot
                    state.fileExists = true
                    return snapshot
                }
            } catch {
                cache.withLock { state in
                    guard state.epoch == epoch else { return }
                    state.digest = nil
                    state.snapshot = nil
                    state.fileExists = (error as? CodexCredentialError) != .missing
                }
                throw error
            }
        }
    }

    private func readStableFile() throws -> Data {
        let fd = open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw errno == ENOENT ? CodexCredentialError.missing : CodexCredentialError.unreadable
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size > 0, before.st_size <= 1_048_576
        else {
            throw CodexCredentialError.unreadable
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount > 0 else { throw CodexCredentialError.changed }
            count += readCount
        }
        var after = stat()
        var current = stat()
        guard fstat(fd, &after) == 0, stat(sourceURL.path, &current) == 0,
            Self.sameFile(before, after), Self.sameFile(after, current)
        else {
            throw CodexCredentialError.changed
        }
        return Data(bytes)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
