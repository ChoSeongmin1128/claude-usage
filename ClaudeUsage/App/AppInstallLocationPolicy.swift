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

struct AppDiskImageSource: Equatable, Sendable {
    let imagePath: String
    let mountPoint: String
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
