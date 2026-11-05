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
    /// Older releases reset every item under their bundle-ID service. Recovery
    /// material lives outside that service so a downgrade cannot erase it.
    static let credentialRecoveryServiceSuffix = ".credential-recovery"

    static func credentialRecoveryService(bundleIdentifier: String) -> String {
        bundleIdentifier + credentialRecoveryServiceSuffix
    }
    static let popoverGeometryLogFileName = "ClaudeUsagePopoverGeometry.log"
    /// 상태 아이템 위치를 저장하는 autosave 이름. 바꾸면 메뉴바 위치를 잃는다.
    static let productionStatusItemAutosaveName = "claudeusage"
    static let stagingStatusItemAutosaveName = "claudeusage-staging"
    /// 상태 버튼의 접근성 제목. macOS 27 MenuBarAgent의 위치 태그와 메뉴바 관리 앱이 이 값으로
    /// 상태 아이템을 식별한다. 앱 이름을 바꿔도 유지하고, 바꾸면 저장된 위치와 숨김 설정이 갈라진다.
    static let statusItemAccessibilityTitle = "ClaudeUsage"

    /// UserDefaults 키. 접두어 "ClaudeUsage."는 저장된 값이므로 바꾸지 않는다.
    static func defaultsKey(_ name: String) -> String {
        "ClaudeUsage.\(name)"
    }
}
