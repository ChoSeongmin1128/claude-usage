import Foundation

/// 앱 이름을 바꿔도 그대로 두는 저장, 배포 식별자. 바꾸면 계정, Keychain 접근, 권한(TCC),
/// 업데이트 경로를 잃는다. 화면에 보이는 이름은 `AppDistribution.current.appName`을 쓴다.
nonisolated enum AppIdentifiers {
    static let productionBundleIdentifier = "com.seongmin.ClaudeUsage"
    static let stagingBundleIdentifier = "com.seongmin.ClaudeUsage.staging"
    static let productionSupportDirectoryName = "ClaudeUsage"
    static let stagingSupportDirectoryName = "ClaudeUsage-stg"
    /// 이전 버전이 채널 사이에 같이 쓰던 Application Support 폴더
    static let legacySharedSupportDirectoryName = "ClaudeUsageShared"
    static let releaseChannelInfoKey = "ClaudeUsageReleaseChannel"
    static let releaseVersionInfoKey = "ClaudeUsageReleaseVersion"
    /// 배포 드라이버가 만드는 업데이트 자산 이름
    static let releaseAssetZipName = "ClaudeUsage.zip"
    static let userAgentProduct = "ClaudeUsage"
    /// bundle identifier를 못 읽을 때와 이전 버전이 쓰던 Keychain service
    static let legacyKeychainService = "ClaudeUsage"
    static let legacyClaudeOAuthKeychainService = "ClaudeUsage.Claude Code-credentials-refreshed"
    static let popoverGeometryLogFileName = "ClaudeUsagePopoverGeometry.log"

    /// UserDefaults 키. 접두어 "ClaudeUsage."는 저장된 값이므로 바꾸지 않는다.
    static func defaultsKey(_ name: String) -> String {
        "ClaudeUsage.\(name)"
    }
}
