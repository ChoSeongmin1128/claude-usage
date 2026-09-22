import Foundation

enum AppInstallLocationKind: String, Sendable {
    case applications
    case userApplications
    case diskImageVolume
    case appTranslocation
    case temporary
    case downloads
    case other
}

enum AppInstallTransferStrategy: Equatable, Sendable {
    case moveSource
    case copySource

    nonisolated static func == (lhs: AppInstallTransferStrategy, rhs: AppInstallTransferStrategy) -> Bool {
        switch (lhs, rhs) {
        case (.moveSource, .moveSource), (.copySource, .copySource):
            return true
        case (.moveSource, .copySource), (.copySource, .moveSource):
            return false
        }
    }
}

struct AppInstallLocationAssessment: Equatable, Sendable {
    let bundlePath: String
    let kind: AppInstallLocationKind

    nonisolated var isStableInstall: Bool {
        kind == .applications || kind == .userApplications
    }

    nonisolated var requiresMovePrompt: Bool {
        !isStableInstall
    }

    nonisolated var preferredTransferStrategy: AppInstallTransferStrategy {
        switch kind {
        case .downloads, .other:
            return .moveSource
        case .applications, .userApplications, .diskImageVolume, .appTranslocation, .temporary:
            return .copySource
        }
    }

    nonisolated var locationDescription: String {
        switch kind {
        case .applications:
            return "Applications 폴더"
        case .userApplications:
            return "사용자 Applications 폴더"
        case .diskImageVolume:
            return "DMG 또는 외부 볼륨"
        case .appTranslocation:
            return "macOS 임시 실행 위치"
        case .temporary:
            return "임시 폴더"
        case .downloads:
            return "Downloads 폴더"
        case .other:
            return "Applications 밖의 위치"
        }
    }
}

/// 이동 프롬프트를 띄울지 여부. 위치 판정(`requiresMovePrompt`)과 분리한 이유는
/// 프롬프트의 목적이 Sparkle 자동 업데이트 신뢰성이고, 자동 업데이트 경로가 없는
/// 개발 빌드는 위치가 불안정해도 경고할 대상이 아니기 때문이다.
enum AppInstallMovePromptPolicy {
    #if DEBUG
    nonisolated static let isDeveloperBuild = true
    #else
    nonisolated static let isDeveloperBuild = false
    #endif

    nonisolated static func shouldPrompt(
        assessment: AppInstallLocationAssessment,
        isDeveloperBuild: Bool = isDeveloperBuild
    ) -> Bool {
        guard assessment.requiresMovePrompt else { return false }
        return !isDeveloperBuild
    }

    /// 목적지에 다른 앱이 있으면 대체하지 않는다. 목적지 이름은 소스 번들 이름에서
    /// 오므로, 채널이 다른 설치본(운영 앱)을 스테이징/개발 빌드가 덮어쓸 수 있다.
    nonisolated static func mayReplace(
        destinationBundleIdentifier: String?,
        destinationExists: Bool,
        ownBundleIdentifier: String?
    ) -> Bool {
        guard destinationExists else { return true }
        guard let destinationBundleIdentifier, let ownBundleIdentifier else { return false }
        return destinationBundleIdentifier == ownBundleIdentifier
    }
}

struct AppDiskImageSource: Equatable, Sendable {
    let imagePath: String
    let mountPoint: String
}

struct AppRunningApplicationSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let isTerminated: Bool
}

enum AppInstallLocationPolicy {
    nonisolated static func currentAssessment() -> AppInstallLocationAssessment {
        assess(bundlePath: Bundle.main.bundlePath)
    }

    nonisolated static func assess(
        bundlePath: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> AppInstallLocationAssessment {
        let normalizedHome = homeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homePrefix = normalizedHome.isEmpty ? "" : "/" + normalizedHome
        let kind: AppInstallLocationKind

        if bundlePath.hasPrefix("/Applications/") {
            kind = .applications
        } else if !homePrefix.isEmpty, bundlePath.hasPrefix("\(homePrefix)/Applications/") {
            kind = .userApplications
        } else if bundlePath.contains("/AppTranslocation/") {
            kind = .appTranslocation
        } else if bundlePath.hasPrefix("/Volumes/") {
            kind = .diskImageVolume
        } else if bundlePath.hasPrefix("/private/var/folders/")
            || bundlePath.hasPrefix("/var/folders/")
            || bundlePath.hasPrefix(NSTemporaryDirectory()) {
            kind = .temporary
        } else if !homePrefix.isEmpty, bundlePath.hasPrefix("\(homePrefix)/Downloads/") {
            kind = .downloads
        } else {
            kind = .other
        }

        return AppInstallLocationAssessment(bundlePath: bundlePath, kind: kind)
    }

    nonisolated static func diskImageSource(
        for bundlePath: String,
        hdiutilInfoPlistData: Data
    ) -> AppDiskImageSource? {
        let sources = diskImageSources(hdiutilInfoPlistData: hdiutilInfoPlistData)
        guard
            !sources.isEmpty
        else {
            return nil
        }

        let normalizedBundlePath = normalizedPath(bundlePath)
        let candidates = sources.filter { source in
            let normalizedMountPoint = normalizedPath(source.mountPoint)
            return normalizedBundlePath == normalizedMountPoint
                || normalizedBundlePath.hasPrefix(normalizedMountPoint + "/")
        }

        return candidates.max { $0.mountPoint.count < $1.mountPoint.count }
    }

    nonisolated static func diskImageSource(
        forAppNamed appName: String,
        bundleIdentifier: String?,
        hdiutilInfoPlistData: Data,
        bundleIdentifierAtPath: (String) -> String?
    ) -> AppDiskImageSource? {
        let normalizedAppName = (appName as NSString).lastPathComponent
        guard !normalizedAppName.isEmpty else { return nil }

        let expectedIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        let candidates = diskImageSources(hdiutilInfoPlistData: hdiutilInfoPlistData).filter { source in
            let candidatePath = normalizedPath((source.mountPoint as NSString).appendingPathComponent(normalizedAppName))
            guard let candidateIdentifier = bundleIdentifierAtPath(candidatePath) else { return false }
            guard let expectedIdentifier else { return true }
            return candidateIdentifier == expectedIdentifier
        }

        // 이름과 번들 ID만으로는 어느 이미지가 설치 원본인지 가릴 수 없다. 서로 다른
        // 이미지가 동시에 붙어 있으면 엉뚱한 파일을 버리는 대신 아무것도 하지 않는다.
        let distinctImages = Set(
            candidates.map { normalizedPath($0.imagePath) }
        )
        guard distinctImages.count <= 1 else { return nil }
        return candidates.max { $0.mountPoint.count < $1.mountPoint.count }
    }

    private nonisolated static func diskImageSources(
        hdiutilInfoPlistData: Data
    ) -> [AppDiskImageSource] {
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: hdiutilInfoPlistData,
                options: [],
                format: nil
            ),
            let root = plist as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else {
            return []
        }

        return images.flatMap { image -> [AppDiskImageSource] in
            guard
                let imagePath = image["image-path"] as? String,
                imagePath.lowercased().hasSuffix(".dmg"),
                let entities = image["system-entities"] as? [[String: Any]]
            else {
                return []
            }

            return entities.compactMap { entity -> AppDiskImageSource? in
                guard let mountPoint = entity["mount-point"] as? String else { return nil }
                return AppDiskImageSource(imagePath: imagePath, mountPoint: mountPoint)
            }
        }
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

enum AppInstallRunningApplicationPolicy {
    nonisolated static func siblingApplicationsToTerminate(
        currentBundleIdentifier: String?,
        currentProcessIdentifier: pid_t,
        runningApplications: [AppRunningApplicationSnapshot]
    ) -> [AppRunningApplicationSnapshot] {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else { return [] }
        return runningApplications.filter { application in
            application.bundleIdentifier == currentBundleIdentifier
                && application.processIdentifier != currentProcessIdentifier
                && !application.isTerminated
        }
    }
}
