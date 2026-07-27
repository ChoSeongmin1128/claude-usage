import AppKit
import CryptoKit
import Foundation
import Network

nonisolated enum AntigravityOAuthLoginRunner {
    nonisolated enum Phase: Sendable, Equatable {
        case waitingBrowser
    }

    nonisolated struct Result: Sendable, Equatable {
        nonisolated enum Outcome: Sendable, Equatable {
            case success(AntigravityOAuthCredentials)
            case cancelled
            case timedOut
            case launchFailed(String)
            case failed(String)
        }

        let outcome: Outcome
    }

    static func run(
        timeout: TimeInterval = 120,
        onPhaseChange: (@Sendable (Phase) -> Void)? = nil
    ) async -> Result {
        guard !Task.isCancelled else {
            return Result(outcome: .cancelled)
        }
        guard let oauthClient = await resolvedClientOffMainActor() else {
            return Result(outcome: .failed(AntigravityOAuthConfig.missingCredentialsMessage))
        }
        guard !Task.isCancelled else {
            return Result(outcome: .cancelled)
        }

        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let pkce = AntigravityOAuthPKCEPair.generate()
        let server = AntigravityLoopbackServer(state: state)

        do {
            let callbackURL = try await server.start()
            try Task.checkCancellation()
            let authURL = try makeAuthorizationURL(
                redirectURL: callbackURL,
                state: state,
                pkce: pkce,
                oauthClient: oauthClient
            )
            onPhaseChange?(.waitingBrowser)

            let opened = await MainActor.run {
                NSWorkspace.shared.open(authURL)
            }
            guard opened else {
                server.stop()
                return Result(outcome: .launchFailed(authURL.absoluteString))
            }

            let callback = try await withThrowingTaskGroup(of: AntigravityOAuthCallback.self) { group in
                group.addTask {
                    try await server.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    server.cancelCallbackWait(with: AntigravityLoginError.timedOut)
                    throw AntigravityLoginError.timedOut
                }
                defer { group.cancelAll() }
                guard let callback = try await group.next() else {
                    throw AntigravityLoginError.timedOut
                }
                return callback
            }
            server.stop()
            try Task.checkCancellation()

            if let error = callback.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                if error == "access_denied" {
                    return Result(outcome: .cancelled)
                }
                return Result(outcome: .failed(error))
            }

            guard callback.returnedState == state else {
                return Result(outcome: .failed("Google 로그인 state가 일치하지 않습니다."))
            }
            guard let code = callback.code?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
                return Result(outcome: .failed("Google 로그인이 authorization code를 반환하지 않았습니다."))
            }

            try Task.checkCancellation()
            let tokenExchange = try await exchangeCodeForTokens(
                code: code,
                redirectURL: callbackURL,
                codeVerifier: pkce.verifier,
                oauthClient: oauthClient
            )
            try Task.checkCancellation()
            let tokenResponse = tokenExchange.response
            let email = try await fetchUserEmail(accessToken: tokenResponse.accessToken)
            try Task.checkCancellation()
            let credentials = AntigravityOAuthCredentials(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                expiryDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
                idToken: tokenResponse.idToken,
                email: email,
                projectID: nil,
                clientID: oauthClient.clientID,
                clientSecret: tokenExchange.clientSecret
            )
            return Result(outcome: .success(credentials))
        } catch is CancellationError {
            server.stop()
            return Result(outcome: .cancelled)
        } catch AntigravityLoginError.timedOut {
            server.stop()
            return Result(outcome: .timedOut)
        } catch let AntigravityLoginError.launchFailed(message) {
            server.stop()
            return Result(outcome: .launchFailed(message))
        } catch {
            server.stop()
            return Result(outcome: .failed(error.localizedDescription))
        }
    }

    private static func resolvedClientOffMainActor() async -> AntigravityOAuthClient? {
        await Task.detached(priority: .userInitiated) {
            AntigravityOAuthConfig.resolvedClient()
        }.value
    }

    private static func makeAuthorizationURL(
        redirectURL: URL,
        state: String,
        pkce: AntigravityOAuthPKCEPair,
        oauthClient: AntigravityOAuthClient
    ) throws -> URL {
        guard var components = URLComponents(url: AntigravityOAuthConfig.authURL, resolvingAgainstBaseURL: false) else {
            throw AntigravityLoginError.invalidAuthorizationURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oauthClient.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AntigravityOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else {
            throw AntigravityLoginError.invalidAuthorizationURL
        }
        return url
    }

    private static func exchangeCodeForTokens(
        code: String,
        redirectURL: URL,
        codeVerifier: String,
        oauthClient: AntigravityOAuthClient
    ) async throws -> TokenExchangeResult {
        var lastInvalidClientMessage: String?
        for clientSecret in oauthClient.tokenClientSecretCandidates {
            do {
                let response = try await exchangeCodeForTokens(
                    code: code,
                    redirectURL: redirectURL,
                    clientID: oauthClient.clientID,
                    clientSecret: clientSecret,
                    codeVerifier: codeVerifier
                )
                return TokenExchangeResult(response: response, clientSecret: clientSecret)
            } catch AntigravityLoginError.invalidClient(let message) {
                lastInvalidClientMessage = message
                continue
            }
        }
        throw AntigravityLoginError.failed(lastInvalidClientMessage ?? "Antigravity OAuth client secret이 유효하지 않습니다.")
    }

    private static func exchangeCodeForTokens(
        code: String,
        redirectURL: URL,
        clientID: String,
        clientSecret: String?,
        codeVerifier: String
    ) async throws -> TokenResponse {
        var request = URLRequest(url: AntigravityOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURL.absoluteString,
            "grant_type": "authorization_code",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityLoginError.failed("토큰 응답이 올바르지 않습니다.")
        }
        guard http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "HTTP \(http.statusCode)"
            let errorPayload = tokenError(from: data)
            if isRetryableClientCredentialError(
                statusCode: http.statusCode,
                errorCode: errorPayload?.code,
                errorDescription: errorPayload?.description,
                clientSecret: clientSecret
            ) {
                throw AntigravityLoginError.invalidClient(message)
            }
            throw AntigravityLoginError.failed(message)
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AntigravityLoginError.failed("토큰 응답을 해석하지 못했습니다.")
        }
    }

    private static func tokenError(from data: Data) -> AntigravityOAuthTokenErrorPayload? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return AntigravityOAuthTokenErrorPayload(
            code: (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            description: (json["error_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isRetryableClientCredentialError(
        statusCode: Int,
        errorCode: String?,
        errorDescription: String?,
        clientSecret: String?
    ) -> Bool {
        if statusCode == 401, errorCode == "invalid_client" {
            return true
        }
        guard clientSecret == nil, errorCode == "invalid_request" else {
            return false
        }
        return errorDescription?.localizedCaseInsensitiveContains("client_secret") == true
    }

    private static func fetchUserEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: AntigravityOAuthConfig.userInfoURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let userInfo = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            return userInfo.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } catch {
            return nil
        }
    }

    private static func formBody(_ values: [String: String?]) -> Data? {
        values
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

private nonisolated struct AntigravityOAuthTokenErrorPayload: Sendable, Equatable {
    let code: String?
    let description: String?
}

private nonisolated struct AntigravityOAuthPKCEPair: Sendable, Equatable {
    let verifier: String
    let challenge: String

    static func generate() -> AntigravityOAuthPKCEPair {
        let verifier = base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return AntigravityOAuthPKCEPair(
            verifier: verifier,
            challenge: base64URL(Data(digest))
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private nonisolated enum AntigravityLoginError: LocalizedError {
    case invalidAuthorizationURL
    case timedOut
    case launchFailed(String)
    case invalidClient(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL:
            return "Antigravity 로그인 URL을 만들지 못했습니다."
        case .timedOut:
            return "Antigravity Google 로그인이 시간 초과되었습니다."
        case .launchFailed(let message):
            return message
        case .invalidClient(let message):
            return message
        case .failed(let message):
            return message
        }
    }
}

private nonisolated struct TokenExchangeResult: Sendable {
    let response: TokenResponse
    let clientSecret: String?
}

private nonisolated struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

private nonisolated struct UserInfoResponse: Decodable {
    let email: String?
}

nonisolated struct AntigravityOAuthCallback {
    let code: String?
    let returnedState: String?
    let error: String?
}

nonisolated enum AntigravityOAuthCallbackParser {
    static func parse(
        from data: Data,
        expectedState: String,
        allowedHost: String?
    ) -> AntigravityOAuthCallback {
        guard let request = String(data: data, encoding: .utf8) else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "callback 요청이 올바르지 않습니다.")
        }

        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "callback 요청이 올바르지 않습니다.")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "GET" else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "callback HTTP method가 올바르지 않습니다.")
        }

        if let allowedHost,
           normalizedHost(from: lines) != allowedHost.lowercased()
        {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "callback host가 올바르지 않습니다.")
        }

        guard let url = URL(string: "http://127.0.0.1\(parts[1])"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return AntigravityOAuthCallback(code: nil, returnedState: nil, error: "callback URL이 올바르지 않습니다.")
        }

        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        let error = components.queryItems?.first(where: { $0.name == "error" })?.value

        guard components.path == "/oauth2callback" else {
            return AntigravityOAuthCallback(code: nil, returnedState: returnedState, error: "예상하지 못한 callback path입니다.")
        }
        if let returnedState, returnedState != expectedState {
            return AntigravityOAuthCallback(code: code, returnedState: returnedState, error: "state가 일치하지 않습니다.")
        }
        return AntigravityOAuthCallback(code: code, returnedState: returnedState, error: error)
    }

    private static func normalizedHost(from lines: [String]) -> String? {
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Host") == .orderedSame
            else {
                continue
            }

            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return nil
    }
}

nonisolated final class AntigravityLoopbackServer: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "claudeusage.antigravity.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var allowedHost: String?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var pendingReadyResult: Result<URL, Error>?
    private var callbackContinuation: CheckedContinuation<AntigravityOAuthCallback, Error>?
    private var pendingCallbackResult: Result<AntigravityOAuthCallback, Error>?
    private var completed = false

    init(state: String) {
        expectedState = state
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        let listener = try NWListener(using: .tcp, on: .any)
        lock.withLock {
            self.listener = listener
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                lock.lock()
                if let pending = pendingReadyResult {
                    pendingReadyResult = nil
                    lock.unlock()
                    switch pending {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    return
                }
                readyContinuation = continuation
                lock.unlock()
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port else {
                            self.finishReady(with: .failure(AntigravityLoginError.failed("로컬 callback port를 확인하지 못했습니다.")))
                            self.finishCallback(with: .failure(AntigravityLoginError.failed("로컬 callback port를 확인하지 못했습니다.")))
                            return
                        }
                        self.allowedHost = "127.0.0.1:\(port.rawValue)"
                        let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth2callback")!
                        self.finishReady(with: .success(url))
                    case .failed(let error):
                        self.finishReady(with: .failure(error))
                        self.finishCallback(with: .failure(error))
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { [weak self] in
            self?.cancelStart()
        }
    }

    func waitForCallback() async throws -> AntigravityOAuthCallback {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                lock.lock()
                defer { lock.unlock() }
                if let pending = pendingCallbackResult {
                    pendingCallbackResult = nil
                    switch pending {
                    case .success(let callback):
                        continuation.resume(
                            returning: callback
                        )
                    case .failure(let error):
                        continuation.resume(
                            throwing: error
                        )
                    }
                    return
                }
                callbackContinuation = continuation
            }
        } onCancel: { [weak self] in
            self?.cancelCallbackWait(
                with: CancellationError()
            )
        }
    }

    func stop() {
        lock.lock()
        let activeListener = listener
        self.listener = nil
        lock.unlock()
        activeListener?.cancel()
    }

    func cancelCallbackWait(with error: Error) {
        stop()
        finishCallback(with: .failure(error))
    }

    private func cancelStart() {
        stop()
        let error = CancellationError()
        finishReady(with: .failure(error))
        finishCallback(with: .failure(error))
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finishCallback(with: .failure(error))
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete {
                self.receive(on: connection, accumulated: buffer)
                return
            }

            let callback = self.parseCallback(from: buffer)
            let response = self.httpResponse(for: callback)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finishCallback(with: .success(callback))
        }
    }

    private func parseCallback(from data: Data) -> AntigravityOAuthCallback {
        AntigravityOAuthCallbackParser.parse(
            from: data,
            expectedState: expectedState,
            allowedHost: allowedHost
        )
    }

    private func httpResponse(for callback: AntigravityOAuthCallback) -> Data {
        let success = callback.error == nil && callback.code?.isEmpty == false
        let status = success ? "200 OK" : "400 Bad Request"
        let title = success ? "Login Successful" : "Login Failed"
        let detail = success
            ? "You can close this window and return to ClaudeUsage."
            : "You can close this window and try again."
        let html = """
        <html>
          <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px; text-align: center;">
            <h1>\(title)</h1>
            <p>\(detail)</p>
          </body>
        </html>
        """
        let body = Data(html.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func finishReady(with result: Result<URL, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        if continuation == nil {
            pendingReadyResult = result
        }
        lock.unlock()
        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func finishCallback(with result: Result<AntigravityOAuthCallback, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        if continuation == nil {
            pendingCallbackResult = result
        }
        lock.unlock()

        guard let continuation else { return }
        switch result {
        case .success(let callback):
            continuation.resume(returning: callback)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension CharacterSet {
    nonisolated static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}
