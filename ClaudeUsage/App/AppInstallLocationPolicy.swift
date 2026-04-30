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
}
