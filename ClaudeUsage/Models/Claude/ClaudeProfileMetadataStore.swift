import Foundation

actor ClaudeProfileMetadataStore {
    private struct StoredProfileMetadata: Codable {
        var organizationUUID: String?
        var subscriptionType: String?
        var rateLimitTier: String?
        var hasExtraUsageEnabled: Bool?
        var billingType: String?
        var accountCreatedAt: Date?
        var subscriptionCreatedAt: Date?
        var lastUpdatedAt: Date?

        init(metadata: ClaudeProfileMetadata) {
            organizationUUID = metadata.organizationUUID
            subscriptionType = metadata.subscriptionType
            rateLimitTier = metadata.rateLimitTier
            hasExtraUsageEnabled = metadata.hasExtraUsageEnabled
            billingType = metadata.billingType
            accountCreatedAt = metadata.accountCreatedAt
            subscriptionCreatedAt = metadata.subscriptionCreatedAt
            lastUpdatedAt = metadata.lastUpdatedAt
        }

        func makeMetadata() -> ClaudeProfileMetadata {
            ClaudeProfileMetadata(
                organizationUUID: organizationUUID,
                subscriptionType: subscriptionType,
                rateLimitTier: rateLimitTier,
                hasExtraUsageEnabled: hasExtraUsageEnabled,
                billingType: billingType,
                accountCreatedAt: accountCreatedAt,
                subscriptionCreatedAt: subscriptionCreatedAt,
                lastUpdatedAt: lastUpdatedAt
            )
        }
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = baseURL
                .appendingPathComponent("ClaudeUsage", isDirectory: true)
                .appendingPathComponent("claude-profile-metadata.json", isDirectory: false)
        }
    }

    func load() -> ClaudeProfileMetadata? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let stored = try? decoder.decode(StoredProfileMetadata.self, from: data) else { return nil }
        return stored.makeMetadata()
    }

    func loadNotificationPolicy() -> ClaudeNotificationPolicy? {
        load().map(ClaudeNotificationPolicy.init(metadata:))
    }

    func update(from credentialsText: String) -> ClaudeProfileMetadata? {
        guard let metadata = Self.parseProfileMetadata(from: credentialsText) else { return nil }
        save(metadata)
        return metadata
    }

    func save(_ metadata: ClaudeProfileMetadata) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(StoredProfileMetadata(metadata: metadata))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Logger.debug("Claude profile metadata 저장 실패: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func parseProfileMetadata(from credentialsText: String) -> ClaudeProfileMetadata? {
        guard let data = credentialsText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let oauth = json["claudeAiOauth"] as? [String: Any]
        let account = json["oauthAccount"] as? [String: Any]

        var metadata = ClaudeProfileMetadata()
        metadata.organizationUUID = firstNonEmptyString(
            account?["organizationUuid"],
            account?["organizationUUID"],
            json["organizationUuid"],
            json["organizationUUID"])
        metadata.subscriptionType = firstNonEmptyString(
            oauth?["subscriptionType"],
            json["subscriptionType"])
        metadata.rateLimitTier = firstNonEmptyString(
            oauth?["rateLimitTier"],
            json["rateLimitTier"])
        metadata.hasExtraUsageEnabled = firstBool(
            account?["hasExtraUsageEnabled"],
            json["hasExtraUsageEnabled"])
        metadata.billingType = firstNonEmptyString(
            account?["billingType"],
            json["billingType"])
        metadata.accountCreatedAt = firstDateValue(
            account?["accountCreatedAt"],
            json["accountCreatedAt"])
        metadata.subscriptionCreatedAt = firstDateValue(
            account?["subscriptionCreatedAt"],
            json["subscriptionCreatedAt"])
        metadata.lastUpdatedAt = Date()

        return metadata.isEmpty ? nil : metadata
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func firstBool(_ values: Any?...) -> Bool? {
        for value in values {
            if let bool = value as? Bool {
                return bool
            }
        }
        return nil
    }

    private static func firstDateValue(_ values: Any?...) -> Date? {
        for value in values {
            if let string = value as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: string) {
                    return date
                }
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: string) {
                    return date
                }
            } else if let date = value as? Date {
                return date
            }
        }
        return nil
    }
}
