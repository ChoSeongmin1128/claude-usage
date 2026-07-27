import Foundation

nonisolated enum AntigravityLocalRPCMethod:
    String,
    CaseIterable,
    Sendable
{
    case retrieveUserQuotaSummary = "RetrieveUserQuotaSummary"
    case getUserStatus = "GetUserStatus"
    case getCommandModelConfigs = "GetCommandModelConfigs"

    private static let servicePath =
        "/exa.language_server_pb.LanguageServerService/"

    var path: String {
        Self.servicePath + rawValue
    }

    /// Deterministic request bytes keep the undocumented local contract narrow.
    /// No caller may supply an arbitrary RPC method or body.
    var requestBody: Data {
        switch self {
        case .retrieveUserQuotaSummary:
            return Data(#"{"forceRefresh":true}"#.utf8)
        case .getUserStatus, .getCommandModelConfigs:
            return Data(
                #"{"metadata":{"extensionName":"antigravity","ideName":"antigravity","ideVersion":"unknown","locale":"en"}}"#
                    .utf8
            )
        }
    }
}

nonisolated enum AntigravityConnectErrorCode:
    String,
    Equatable,
    Sendable
{
    case cancelled
    case deadlineExceeded
    case permissionDenied
    case resourceExhausted
    case unimplemented
    case internalFailure
    case unavailable
    case unauthenticated
    case unknown

    init(rawValueOrNumber value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if let numeric = Int(normalized) {
            self = Self(grpcCode: numeric)
            return
        }
        switch normalized {
        case "cancelled", "canceled":
            self = .cancelled
        case "deadline_exceeded":
            self = .deadlineExceeded
        case "permission_denied":
            self = .permissionDenied
        case "resource_exhausted":
            self = .resourceExhausted
        case "unimplemented":
            self = .unimplemented
        case "internal":
            self = .internalFailure
        case "unavailable":
            self = .unavailable
        case "unauthenticated":
            self = .unauthenticated
        default:
            self = .unknown
        }
    }

    init(grpcCode: Int) {
        switch grpcCode {
        case 1:
            self = .cancelled
        case 4:
            self = .deadlineExceeded
        case 7:
            self = .permissionDenied
        case 8:
            self = .resourceExhausted
        case 12:
            self = .unimplemented
        case 13:
            self = .internalFailure
        case 14:
            self = .unavailable
        case 16:
            self = .unauthenticated
        default:
            self = .unknown
        }
    }
}

nonisolated enum AntigravityLocalRPCError:
    Error,
    Equatable,
    Sendable
{
    case cancelled
    case deadlineExceeded
    case invalidEndpoint
    case endpointOwnershipChanged
    case tlsRejected
    case redirectRejected
    case responseTooLarge(limit: Int)
    case transportFailure
    case invalidHTTPResponse
    case unsupportedHTTPStatus(Int)
    case authenticationRejected
    case rateLimited
    case serverRejected
    case malformedPayload
    case remoteRejected(AntigravityConnectErrorCode)
    case groupedQuotaUnavailable
}

nonisolated enum AntigravityLegacyFallbackReason:
    Equatable,
    Sendable
{
    case unsupportedHTTPStatus(Int)
    case connectUnimplemented
    case groupedQuotaUnavailable
}

nonisolated enum AntigravityLegacyFallbackPolicy {
    static func reason(
        for error: AntigravityLocalRPCError
    ) -> AntigravityLegacyFallbackReason? {
        switch error {
        case let .unsupportedHTTPStatus(status)
            where status == 404 || status == 405 || status == 501:
            return .unsupportedHTTPStatus(status)
        case .remoteRejected(.unimplemented):
            return .connectUnimplemented
        case .groupedQuotaUnavailable:
            return .groupedQuotaUnavailable
        default:
            return nil
        }
    }
}

nonisolated struct AntigravityLocalRPCResponse:
    Equatable,
    Sendable
{
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            normalizedHeaders[key.lowercased()] = value
        }
        self.headers = normalizedHeaders
        self.body = body
    }
}

nonisolated enum AntigravityLocalRPCResponseValidator {
    static func validate(_ response: AntigravityLocalRPCResponse) throws {
        let remoteErrors = remoteErrors(in: response)

        // A capability-looking Connect signal may never mask an operational
        // or security failure carried by another header or the error envelope.
        // Resolve every typed signal before considering legacy fallback.
        if let failure = strongestNonCapabilityFailure(in: remoteErrors) {
            throw failure
        }

        if let failure = httpFailure(response.statusCode),
           AntigravityLegacyFallbackPolicy.reason(for: failure) == nil
        {
            throw failure
        }

        if remoteErrors.contains(.remoteRejected(.unimplemented)) {
            throw AntigravityLocalRPCError.remoteRejected(.unimplemented)
        }

        if let failure = httpFailure(response.statusCode) {
            throw failure
        }
    }

    private static func remoteErrors(
        in response: AntigravityLocalRPCResponse
    ) -> [AntigravityLocalRPCError] {
        var errors: [AntigravityLocalRPCError] = []
        for key in ["grpc-status", "connect-error-code"] {
            guard let headerCode = response.headers[key] else {
                continue
            }
            let normalized = headerCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized != "0"
                && normalized != "ok"
                && normalized != "success"
            {
                errors.append(
                    mappedRemoteError(
                        AntigravityConnectErrorCode(
                            rawValueOrNumber: normalized
                        )
                    )
                )
            }
        }

        errors.append(
            contentsOf: errorEnvelopeCodes(in: response.body)
                .map(mappedRemoteError)
        )
        return errors
    }

    private static func strongestNonCapabilityFailure(
        in errors: [AntigravityLocalRPCError]
    ) -> AntigravityLocalRPCError? {
        errors
            .filter {
                AntigravityLegacyFallbackPolicy.reason(for: $0) == nil
            }
            .min {
                failurePriority($0) < failurePriority($1)
            }
    }

    private static func failurePriority(
        _ error: AntigravityLocalRPCError
    ) -> Int {
        switch error {
        case .authenticationRejected:
            return 0
        case .rateLimited:
            return 1
        case .deadlineExceeded:
            return 2
        case .cancelled:
            return 3
        case .remoteRejected:
            return 4
        default:
            return 5
        }
    }

    private static func httpFailure(
        _ statusCode: Int
    ) -> AntigravityLocalRPCError? {
        switch statusCode {
        case 200:
            return nil
        case 401, 403:
            return .authenticationRejected
        case 429:
            return .rateLimited
        case 404, 405, 501:
            return .unsupportedHTTPStatus(statusCode)
        case 500...599:
            return .serverRejected
        default:
            return .unsupportedHTTPStatus(statusCode)
        }
    }

    private static func mappedRemoteError(
        _ code: AntigravityConnectErrorCode
    ) -> AntigravityLocalRPCError {
        switch code {
        case .cancelled:
            return .cancelled
        case .deadlineExceeded:
            return .deadlineExceeded
        case .permissionDenied, .unauthenticated:
            return .authenticationRejected
        case .resourceExhausted:
            return .rateLimited
        case .unimplemented:
            return .remoteRejected(.unimplemented)
        case .internalFailure, .unavailable, .unknown:
            return .remoteRejected(code)
        }
    }

    private static func errorEnvelopeCodes(
        in data: Data
    ) -> [AntigravityConnectErrorCode] {
        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return []
        }

        var codes: [AntigravityConnectErrorCode] = []
        if let rawCode = root["code"] {
            switch parsedErrorCode(rawCode) {
            case .success:
                break
            case .failure(let code):
                codes.append(code)
            }
        }

        if let rawError = root["error"] {
            if let object = rawError as? [String: Any] {
                let countBeforeObject = codes.count
                for key in ["code", "status", "grpcCode"] {
                    guard let value = object[key] else { continue }
                    switch parsedErrorCode(value) {
                    case .success:
                        continue
                    case .failure(let code):
                        codes.append(code)
                    }
                }
                if !object.isEmpty && codes.count == countBeforeObject {
                    codes.append(.unknown)
                }
            } else if let string = rawError as? String {
                let trimmed = string.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !trimmed.isEmpty {
                    codes.append(
                        AntigravityConnectErrorCode(
                            rawValueOrNumber: trimmed
                        )
                    )
                }
            } else if !(rawError is NSNull) {
                codes.append(.unknown)
            }
        }

        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            codes.append(.unknown)
        }
        return codes
    }

    private enum ParsedErrorCode {
        case success
        case failure(AntigravityConnectErrorCode)
    }

    private static func parsedErrorCode(
        _ rawCode: Any
    ) -> ParsedErrorCode {
        if let number = rawCode as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return .failure(.unknown)
            }
            let value = number.intValue
            return value == 0
                ? .success
                : .failure(AntigravityConnectErrorCode(grpcCode: value))
        }
        if let string = rawCode as? String {
            let normalized = string
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if normalized == "0"
                || normalized == "ok"
                || normalized == "success"
            {
                return .success
            }
            return .failure(
                AntigravityConnectErrorCode(
                    rawValueOrNumber: normalized
                )
            )
        }
        return .failure(.unknown)
    }
}

nonisolated struct AntigravityLocalAccountIdentity:
    Equatable,
    Sendable
{
    let identity: ProviderAccountIdentity?
    let plan: String?
}

nonisolated enum AntigravityLocalIdentityDecoder {
    static func decode(_ data: Data) throws -> AntigravityLocalAccountIdentity {
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityLocalRPCError.malformedPayload
        }
        guard let root = rootValue as? [String: Any] else {
            throw AntigravityLocalRPCError.malformedPayload
        }
        let payload = root["response"] as? [String: Any] ?? root
        guard let userStatus = payload["userStatus"] as? [String: Any] else {
            throw AntigravityLocalRPCError.malformedPayload
        }

        let email = nonEmptyString(userStatus["email"])
        let tier = userStatus["userTier"] as? [String: Any]
        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let plan = nonEmptyString(tier?["name"])
            ?? [
                "planDisplayName",
                "displayName",
                "productName",
                "planName",
                "planShortName",
            ].lazy.compactMap { nonEmptyString(planInfo?[$0]) }.first

        return AntigravityLocalAccountIdentity(
            identity: email.map {
                ProviderAccountIdentity(
                    stableAccountID: nil,
                    email: $0
                )
            },
            plan: plan
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated struct AntigravityLegacyCapabilityEvidence:
    Equatable,
    Sendable
{
    let method: AntigravityLocalRPCMethod
    let identity: ProviderAccountIdentity?
    let plan: String?
    let modelConfigCount: Int
}

nonisolated enum AntigravityLegacyCapabilityDecoder {
    static func decode(
        _ data: Data,
        method: AntigravityLocalRPCMethod
    ) throws -> AntigravityLegacyCapabilityEvidence {
        guard method == .getUserStatus
                || method == .getCommandModelConfigs
        else {
            throw AntigravityLocalRPCError.malformedPayload
        }
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityLocalRPCError.malformedPayload
        }
        guard let root = rootValue as? [String: Any] else {
            throw AntigravityLocalRPCError.malformedPayload
        }
        let payload = root["response"] as? [String: Any] ?? root

        if method == .getUserStatus {
            let identity = try AntigravityLocalIdentityDecoder.decode(data)
            let userStatus = payload["userStatus"] as? [String: Any]
            let cascade = userStatus?["cascadeModelConfigData"]
                as? [String: Any]
            let configs = cascade?["clientModelConfigs"] as? [Any] ?? []
            return AntigravityLegacyCapabilityEvidence(
                method: method,
                identity: identity.identity,
                plan: identity.plan,
                modelConfigCount: configs.count
            )
        }

        guard let configs = payload["clientModelConfigs"] as? [Any] else {
            throw AntigravityLocalRPCError.malformedPayload
        }
        return AntigravityLegacyCapabilityEvidence(
            method: method,
            identity: nil,
            plan: nil,
            modelConfigCount: configs.count
        )
    }
}
