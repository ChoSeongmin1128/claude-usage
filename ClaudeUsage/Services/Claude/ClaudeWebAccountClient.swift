import Foundation

nonisolated struct ClaudeWebAccountSnapshot: Sendable {
    let accountID: String?
    let email: String?
    let organizations: [ClaudeAPIService.OrganizationSummary]

    init(data: Data) throws {
        guard let account = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parseError
        }
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        accountID = text(account["uuid"])
        email = text(account["email_address"])
        organizations = (account["memberships"] as? [[String: Any]] ?? [])
            .compactMap { $0["organization"] as? [String: Any] }
            .compactMap(ClaudeAPIService.OrganizationSummary.init(json:))
    }

    func identity(organizationID: String) -> UsageAccountIdentity? {
        guard let organization = organizations.first(where: { $0.id == organizationID }) else { return nil }
        return UsageAccountIdentity(
            accountID: accountID, organizationID: organization.id,
            email: email, organizationName: organization.name)
    }
}

nonisolated enum ClaudeWebAccountClient {
    static func fetch(sessionKey: String, runner: ClaudeAPIService.HTTPRunner) async throws -> ClaudeWebAccountSnapshot {
        var request = URLRequest(url: ClaudeEndpoints.accountURL)
        request.timeoutInterval = ClaudeEndpoints.requestTimeout
        ClaudeEndpoints.applyWebHeaders(to: &request, sessionKey: sessionKey)
        let (data, response) = try await runner(request)
        try Task.checkCancellation()
        let http = response as? HTTPURLResponse
        guard let status = http?.statusCode, (200...299).contains(status) else {
            throw ClaudeHTTPTransport.classify(statusCode: http?.statusCode ?? 0, data: data, response: http)
        }
        return try ClaudeWebAccountSnapshot(data: data)
    }
}

nonisolated struct ClaudeValidatedWebSession: Sendable {
    let usage: ClaudeUsageResponse
    let identity: UsageAccountIdentity
}
