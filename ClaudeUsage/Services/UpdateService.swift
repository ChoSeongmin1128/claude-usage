//
//  UpdateService.swift
//  ClaudeUsage
//
//  GitHub Releases 기반 자동 업데이트
//

import Foundation
import AppKit

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

actor UpdateService {
    static let shared = UpdateService()

    private let repoOwner = "ChoSeongmin1128"
    private let repoName = "claude-usage"

    // MARK: - Check for Updates

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

            // .zip 에셋 찾기
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

    // MARK: - Open Release Page

    func releasePageURL() -> URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
    }
}
