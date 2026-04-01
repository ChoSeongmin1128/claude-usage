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
}
