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
        AppIdentifiers.releaseChannelInfoKey

    let channel: ClaudeUsageReleaseChannel
    let appName: String
    let bundleIdentifier: String
    let applicationSupportDirectoryName: String

    var settingsWindowTitle: String {
        "\(appName) 설정"
    }

    func versionLabel(version: String, build: String?, releaseVersion: String?) -> String {
        if channel == .prod, releaseVersion == version { return "v\(version)" }
        let prefix = "\(version)-stg."
        if channel == .staging, let releaseVersion, releaseVersion.hasPrefix(prefix) {
            let suffix = String(releaseVersion.dropFirst(prefix.count))
            if let candidate = Int(suffix), candidate > 0, String(candidate) == suffix {
                return "v\(releaseVersion)"
            }
        }
        return "v\(version)-beta (빌드 \(build ?? "?"))"
    }

    static func resolve(
        releaseChannelValue: String?,
        bundleIdentifier: String?,
        displayName: String? = nil
    ) -> Self {
        let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtName = displayName?.isEmpty == false && displayName?.hasPrefix("$(") == false ? displayName : nil
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
                appName: builtName ?? "ClaudeUsage-stg",
                bundleIdentifier:
                    bundleIdentifier
                    ?? AppIdentifiers.stagingBundleIdentifier,
                applicationSupportDirectoryName:
                    AppIdentifiers.stagingSupportDirectoryName
            )
        }

        return Self(
            channel: .prod,
            appName: builtName ?? "ClaudeUsage",
            bundleIdentifier:
                bundleIdentifier
                ?? AppIdentifiers.productionBundleIdentifier,
            applicationSupportDirectoryName:
                AppIdentifiers.productionSupportDirectoryName
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
                Bundle.main.bundleIdentifier,
            displayName:
                Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        )
    }
}
