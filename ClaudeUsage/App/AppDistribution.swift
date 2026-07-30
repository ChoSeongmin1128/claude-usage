import Foundation

nonisolated enum ClaudeUsageReleaseChannel:
    String,
    Equatable,
    Sendable
{
    case prod
    case staging
}

nonisolated struct AppDistributionDescriptor:
    Equatable,
    Sendable
{
    static let releaseChannelInfoKey =
        "ClaudeUsageReleaseChannel"

    let channel: ClaudeUsageReleaseChannel
    let appName: String
    let bundleIdentifier: String
    let applicationSupportDirectoryName: String

    static func resolve(
        releaseChannelValue: String?,
        bundleIdentifier: String?
    ) -> Self {
        let normalizedChannel =
            releaseChannelValue?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .lowercased()
        let isStaging =
            normalizedChannel == "staging"
            || bundleIdentifier?
                .hasSuffix(".staging") == true

        if isStaging {
            return Self(
                channel: .staging,
                appName: "ClaudeUsage-stg",
                bundleIdentifier:
                    bundleIdentifier
                    ?? "com.seongmin.ClaudeUsage.staging",
                applicationSupportDirectoryName:
                    "ClaudeUsage-stg"
            )
        }

        return Self(
            channel: .prod,
            appName: "ClaudeUsage",
            bundleIdentifier:
                bundleIdentifier
                ?? "com.seongmin.ClaudeUsage",
            applicationSupportDirectoryName:
                "ClaudeUsage"
        )
    }
}

nonisolated enum AppDistribution {
    static var current: AppDistributionDescriptor {
        AppDistributionDescriptor.resolve(
            releaseChannelValue:
                Bundle.main.object(
                    forInfoDictionaryKey:
                        AppDistributionDescriptor
                            .releaseChannelInfoKey
                ) as? String,
            bundleIdentifier:
                Bundle.main.bundleIdentifier
        )
    }
}
