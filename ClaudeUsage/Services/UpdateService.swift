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

actor UpdateService {
    static let shared = UpdateService()

    private let repoOwner = "ChoSeongmin1128"
    private let repoName = "claude-usage"

    // MARK: - Check for Updates

    func checkForUpdates() async -> UpdateInfo? {
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                Logger.warning("업데이트 확인 실패: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return nil
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

            guard remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                Logger.info("최신 버전 사용 중: \(currentVersion)")
                return nil
            }

            // .zip 에셋 찾기
            guard let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let downloadURLString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                Logger.warning("업데이트 zip 에셋을 찾을 수 없음")
                return nil
            }

            let releaseNotes = json["body"] as? String ?? ""

            Logger.info("새 버전 발견: \(remoteVersion) (현재: \(currentVersion))")
            return UpdateInfo(version: remoteVersion, downloadURL: downloadURL, releaseNotes: releaseNotes)

        } catch {
            Logger.error("업데이트 확인 오류: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Download and Install

    func downloadAndInstall(from url: URL) async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsage-update")

        // 임시 디렉토리 정리 및 생성
        try? FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // 1. zip 다운로드
        Logger.info("업데이트 다운로드 시작: \(url)")
        let (zipData, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        let zipPath = tmpDir.appendingPathComponent("ClaudeUsage.zip")
        try zipData.write(to: zipPath)
        Logger.info("다운로드 완료: \(zipData.count) bytes")

        // 2. unzip
        let unzipProcess = Process()
        unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProcess.arguments = ["-o", zipPath.path, "-d", tmpDir.path]
        unzipProcess.standardOutput = nil
        unzipProcess.standardError = nil
        try unzipProcess.run()
        unzipProcess.waitUntilExit()

        guard unzipProcess.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        // 3. .app 찾기
        let contents = try FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
        guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFound
        }

        // 4. 현재 앱 교체
        let currentApp = Bundle.main.bundleURL
        let backupPath = currentApp.deletingLastPathComponent().appendingPathComponent("ClaudeUsage.app.old")

        // 백업 제거 (이전 백업이 있으면)
        try? FileManager.default.removeItem(at: backupPath)

        // 현재 앱 → 백업
        try FileManager.default.moveItem(at: currentApp, to: backupPath)

        // 새 앱 → 현재 위치
        try FileManager.default.moveItem(at: newApp, to: currentApp)

        Logger.info("앱 교체 완료, 재실행 예약")

        // 5. 재실행
        await MainActor.run {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", currentApp.path]
            try? task.run()

            // 약간의 딜레이 후 종료
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Error

enum UpdateError: LocalizedError {
    case downloadFailed
    case unzipFailed
    case appNotFound

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "다운로드에 실패했습니다"
        case .unzipFailed: return "압축 해제에 실패했습니다"
        case .appNotFound: return "업데이트 앱을 찾을 수 없습니다"
        }
    }
}
