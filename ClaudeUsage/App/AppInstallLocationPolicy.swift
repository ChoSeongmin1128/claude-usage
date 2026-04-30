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

struct AppInstallLocationAssessment: Equatable, Sendable {
    let bundlePath: String
    let kind: AppInstallLocationKind

    nonisolated var isStableInstall: Bool {
        kind == .applications || kind == .userApplications
    }

    nonisolated var requiresMovePrompt: Bool {
        !isStableInstall
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
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: hdiutilInfoPlistData,
                options: [],
                format: nil
            ),
            let root = plist as? [String: Any],
            let images = root["images"] as? [[String: Any]]
        else {
            return nil
        }

        let normalizedBundlePath = normalizedPath(bundlePath)
        let candidates = images.compactMap { image -> AppDiskImageSource? in
            guard
                let imagePath = image["image-path"] as? String,
                imagePath.lowercased().hasSuffix(".dmg"),
                let entities = image["system-entities"] as? [[String: Any]]
            else {
                return nil
            }

            for entity in entities {
                guard let mountPoint = entity["mount-point"] as? String else { continue }
                let normalizedMountPoint = normalizedPath(mountPoint)
                guard normalizedBundlePath == normalizedMountPoint
                    || normalizedBundlePath.hasPrefix(normalizedMountPoint + "/")
                else {
                    continue
                }
                return AppDiskImageSource(imagePath: imagePath, mountPoint: mountPoint)
            }

            return nil
        }

        return candidates.max { $0.mountPoint.count < $1.mountPoint.count }
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
