//
//  UpdateService.swift
//  ClaudeUsage
//
//  Sparkle 준비 상태에 따라 업데이트 엔진을 선택합니다.
//

import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

struct UpdateInfo {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
}

enum UpdateCheckResult {
    case available(UpdateInfo)
    case upToDate
    case error(String)
}

protocol AppUpdateEngine {
    func modeSummary() async -> String
    func checkForUpdates() async -> UpdateCheckResult
    func latestDownloadURL() async -> URL
    func usesExternalScheduler() async -> Bool
    func supportsInteractiveCheck() async -> Bool
    func performInteractiveCheck() async -> String?
}

struct GitHubReleaseUpdateEngine: AppUpdateEngine {
    private let repoOwner = "ChoSeongmin1128"
    private let repoName = "claude-usage"
    private let modeDescription: String

    init(modeDescription: String = "현재는 GitHub Release 수동 다운로드 엔진을 사용 중입니다") {
        self.modeDescription = modeDescription
    }

    func modeSummary() async -> String {
        modeDescription
    }

    func checkForUpdates() async -> UpdateCheckResult {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return .error("잘못된 URL") }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsage", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("응답 없음")
            }

            guard httpResponse.statusCode == 200 else {
                let code = httpResponse.statusCode
                let msg = code == 403 ? "요청 한도 초과 (잠시 후 재시도)" : "HTTP \(code)"
                Logger.warning("업데이트 확인 실패: HTTP \(code)")
                return .error(msg)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return .error("응답 파싱 실패")
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

            guard remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                Logger.info("최신 버전 사용 중: \(currentVersion)")
                return .upToDate
            }

            guard let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let downloadURLString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                Logger.warning("업데이트 zip 에셋을 찾을 수 없음")
                return .error("다운로드 파일 없음")
            }

            let releaseNotes = json["body"] as? String ?? ""

            Logger.info("새 버전 발견: \(remoteVersion) (현재: \(currentVersion))")
            return .available(UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: releaseNotes))
        } catch {
            Logger.error("업데이트 확인 오류: \(error.localizedDescription)")
            return .error(error.localizedDescription)
        }
    }

    func latestDownloadURL() async -> URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/ClaudeUsage.zip")!
    }

    func usesExternalScheduler() async -> Bool { false }

    func supportsInteractiveCheck() async -> Bool { false }

    func performInteractiveCheck() async -> String? { nil }
}

#if canImport(Sparkle)
@MainActor
final class SparkleUpdateEngine: NSObject, AppUpdateEngine {
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func makeIfConfigured() -> SparkleUpdateEngine? {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return SparkleUpdateEngine()
    }

    func modeSummary() async -> String {
        "Sparkle 자동업데이트 엔진을 사용 중입니다"
    }

    func checkForUpdates() async -> UpdateCheckResult {
        .upToDate
    }

    func latestDownloadURL() async -> URL {
        URL(string: "https://github.com/ChoSeongmin1128/claude-usage/releases/latest")!
    }

    func usesExternalScheduler() async -> Bool { true }

    func supportsInteractiveCheck() async -> Bool { true }

    func performInteractiveCheck() async -> String? {
        updaterController.checkForUpdates(nil)
        return "Sparkle 업데이트 확인을 시작했습니다"
    }
}
#endif

enum UpdateEngineFactory {
    static func makeDefaultEngine() async -> any AppUpdateEngine {
        #if canImport(Sparkle)
        if let sparkleEngine = await MainActor.run(body: {
            SparkleUpdateEngine.makeIfConfigured()
        }) {
            return sparkleEngine
        }

        return GitHubReleaseUpdateEngine(
            modeDescription: "Sparkle는 통합되었지만 appcast/feed가 아직 설정되지 않아 GitHub Release 엔진을 사용 중입니다"
        )
        #else
        return GitHubReleaseUpdateEngine()
        #endif
    }
}

actor UpdateService {
    static let shared = UpdateService()

    private var engine: (any AppUpdateEngine)?

    init(engine: (any AppUpdateEngine)? = nil) {
        self.engine = engine
    }

    private func resolvedEngine() async -> any AppUpdateEngine {
        if let engine {
            return engine
        }

        let resolved = await UpdateEngineFactory.makeDefaultEngine()
        engine = resolved
        return resolved
    }

    func checkForUpdates() async -> UpdateCheckResult {
        let engine = await resolvedEngine()
        return await engine.checkForUpdates()
    }

    func latestDownloadURL() async -> URL {
        let engine = await resolvedEngine()
        return await engine.latestDownloadURL()
    }

    func currentModeSummary() async -> String {
        let engine = await resolvedEngine()
        return await engine.modeSummary()
    }

    func usesExternalScheduler() async -> Bool {
        let engine = await resolvedEngine()
        return await engine.usesExternalScheduler()
    }

    func supportsInteractiveCheck() async -> Bool {
        let engine = await resolvedEngine()
        return await engine.supportsInteractiveCheck()
    }

    func performInteractiveCheck() async -> String? {
        let engine = await resolvedEngine()
        return await engine.performInteractiveCheck()
    }
}
