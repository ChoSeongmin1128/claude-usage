import XCTest
@testable import ClaudeUsage

@MainActor
final class CodexTokenRefreshRecoveryTests: XCTestCase {
    override func tearDown() {
        CodexURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testAccessJWTExpiryIsRecognizedWithoutExpiresAtField() throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let authPath = tempDirectory.appendingPathComponent("auth.json")
        try writeAuthJSON(
            accessToken: makeJWT(expiration: Date(timeIntervalSinceNow: -600)),
            refreshToken: "refresh",
            to: authPath
        )

        let manager = CodexAuthManager(authJsonPath: authPath.path)
        let token = try XCTUnwrap(manager.getToken())

        XCTAssertTrue(token.isExpired)
        XCTAssertTrue(token.expiresAtIsExplicit)
    }

    func testRecoverFromUnauthorizedReloadsChangedAuthJsonWithoutRefresh() async throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let authPath = tempDirectory.appendingPathComponent("auth.json")
        try writeAuthJSON(accessToken: "old-access", refreshToken: "old-refresh", to: authPath)

        let recorder = CodexRequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)
            return httpResponse(for: request, statusCode: 500, body: "{}")
        }
        let manager = CodexAuthManager(authJsonPath: authPath.path, urlSession: session)

        XCTAssertEqual(manager.getToken()?.accessToken, "old-access")
        try writeAuthJSON(accessToken: "new-access", refreshToken: "new-refresh", to: authPath)

        let result = await manager.recoverFromUnauthorized(failedAccessToken: "old-access")

        guard case .success(let token) = result else {
            return XCTFail("auth.json reload should recover without refresh, got \(result)")
        }
        XCTAssertEqual(token.accessToken, "new-access")
        XCTAssertEqual(recorder.count(where: { $0.url.host == "auth.openai.com" }), 0)
    }

    func testFetchUsageRefreshesOnceAfterUnauthorizedAndPersistsRotatedToken() async throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let authPath = tempDirectory.appendingPathComponent("auth.json")
        try writeAuthJSON(accessToken: "old-access", refreshToken: "old-refresh", to: authPath)

        let recorder = CodexRequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)

            if request.url?.host == "auth.openai.com" {
                return httpResponse(
                    for: request,
                    statusCode: 200,
                    body: """
                    {
                      "access_token": "new-access",
                      "refresh_token": "new-refresh",
                      "id_token": "new-id-token",
                      "expires_in": 3600
                    }
                    """
                )
            }

            if request.url?.host == "chatgpt.test" {
                switch request.value(forHTTPHeaderField: "Authorization") {
                case "Bearer old-access":
                    return httpResponse(for: request, statusCode: 401, body: "{}")
                case "Bearer new-access":
                    return httpResponse(for: request, statusCode: 200, body: usageJSON(primary: 42))
                default:
                    return httpResponse(for: request, statusCode: 403, body: "{}")
                }
            }

            return httpResponse(for: request, statusCode: 500, body: "{}")
        }

        let manager = CodexAuthManager(authJsonPath: authPath.path, urlSession: session)
        let service = CodexAPIService(
            baseURL: URL(string: "https://chatgpt.test/backend-api")!,
            urlSession: session,
            authManager: manager
        )

        let usage = try await service.fetchUsage()

        XCTAssertEqual(usage.primaryPercentage, 42)
        XCTAssertEqual(recorder.count(where: { $0.url.host == "chatgpt.test" }), 2)
        XCTAssertEqual(recorder.count(where: { $0.url.host == "auth.openai.com" }), 1)

        let persistedTokens = try readPersistedTokens(from: authPath)
        XCTAssertEqual(persistedTokens["access_token"] as? String, "new-access")
        XCTAssertEqual(persistedTokens["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(persistedTokens["id_token"] as? String, "new-id-token")
    }

    func testFetchUsageDoesNotLoopWhenRefreshTokenIsPermanentFailure() async throws {
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let authPath = tempDirectory.appendingPathComponent("auth.json")
        try writeAuthJSON(accessToken: "old-access", refreshToken: "old-refresh", to: authPath)

        let recorder = CodexRequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)

            if request.url?.host == "auth.openai.com" {
                return httpResponse(
                    for: request,
                    statusCode: 401,
                    body: #"{ "error": { "code": "refresh_token_reused" } }"#
                )
            }

            if request.url?.host == "chatgpt.test" {
                return httpResponse(for: request, statusCode: 401, body: "{}")
            }

            return httpResponse(for: request, statusCode: 500, body: "{}")
        }

        let manager = CodexAuthManager(authJsonPath: authPath.path, urlSession: session)
        let service = CodexAPIService(
            baseURL: URL(string: "https://chatgpt.test/backend-api")!,
            urlSession: session,
            authManager: manager
        )

        do {
            _ = try await service.fetchUsage()
            XCTFail("refresh_token_reused should require reauth")
        } catch APIError.codexReauthRequired(let reason) {
            XCTAssertEqual(reason, "refresh_token_reused")
        } catch {
            XCTFail("Expected codexReauthRequired, got \(error)")
        }

        XCTAssertEqual(recorder.count(where: { $0.url.host == "chatgpt.test" }), 1)
        XCTAssertEqual(recorder.count(where: { $0.url.host == "auth.openai.com" }), 1)
    }
}

private struct CodexRecordedRequest {
    let url: URL
}

private final class CodexRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CodexRecordedRequest] = []

    func record(_ request: URLRequest) {
        guard let url = request.url else { return }
        lock.lock()
        requests.append(CodexRecordedRequest(url: url))
        lock.unlock()
    }

    func count(where predicate: (CodexRecordedRequest) -> Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter(predicate).count
    }
}

private final class CodexURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedSession(
    handler: @escaping (URLRequest) -> (HTTPURLResponse, Data)
) -> URLSession {
    CodexURLProtocolStub.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private func httpResponse(
    for request: URLRequest,
    statusCode: Int,
    body: String
) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

private func usageJSON(primary: Double) -> String {
    """
    {
      "rate_limit": {
        "primary_window": {
          "used_percent": \(primary),
          "reset_at": 1700000000
        }
      }
    }
    """
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudeUsageCodexTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeAuthJSON(
    accessToken: String,
    refreshToken: String?,
    to path: URL
) throws {
    var tokens: [String: Any] = ["access_token": accessToken]
    if let refreshToken {
        tokens["refresh_token"] = refreshToken
    }
    let json: [String: Any] = [
        "tokens": tokens,
        "last_refresh": "2026-05-01T00:00:00.000Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: path, options: [.atomic])
}

private func readPersistedTokens(from path: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: path)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(json["tokens"] as? [String: Any])
}

private func makeJWT(expiration: Date) throws -> String {
    let header = try base64URLJSONObject(["alg": "none", "typ": "JWT"])
    let payload = try base64URLJSONObject(["exp": Int(expiration.timeIntervalSince1970)])
    return "\(header).\(payload).signature"
}

private func base64URLJSONObject(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return data
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
