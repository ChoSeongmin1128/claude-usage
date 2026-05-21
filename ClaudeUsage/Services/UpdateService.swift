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

struct UpdateInfo: Sendable, Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String
}

struct UpdateEngineStatus: Sendable, Equatable {
    let modeSummary: String
    let sparkleIntegrated: Bool
    let feedConfigured: Bool
    let publicKeyConfigured: Bool

    nonisolated var usesSparkleReadyPath: Bool {
        sparkleIntegrated && feedConfigured && publicKeyConfigured
    }

    nonisolated var missingSparkleRequirements: [String] {
        var items: [String] = []
        if !feedConfigured {
            items.append("appcast")
        }
        if !publicKeyConfigured {
            items.append("공개키")
        }
        return items
    }

    nonisolated func replacing(modeSummary: String) -> UpdateEngineStatus {
        UpdateEngineStatus(
            modeSummary: modeSummary,
            sparkleIntegrated: sparkleIntegrated,
            feedConfigured: feedConfigured,
            publicKeyConfigured: publicKeyConfigured
        )
    }
}

private enum UpdateEngineMessages {
    nonisolated static let githubFallback = "새 버전이 있으면 다운로드 페이지로 안내합니다"
    nonisolated static let sparkleSchedulerReady = "30분마다 새 버전을 확인하고, 있으면 자동으로 준비합니다"
    nonisolated static let sparkleInteractiveStarted = "업데이트 확인 창을 열었습니다"
    nonisolated static let updateSessionInProgress = "이미 업데이트를 확인하고 있습니다"
    nonisolated static let downloadCancelled = "업데이트 다운로드를 취소했습니다"

    nonisolated static func sparkleSchedulerReadyMessage(usingFeedOverride: Bool) -> String {
        return sparkleSchedulerReady
    }
}

private enum UpdateSessionOrigin: Sendable {
    case interactive
    case background
    case scheduled
}

enum UpdateCheckResult: Sendable {
    case available(UpdateInfo)
    case upToDate(message: String?)
    case error(String)
}

protocol AppUpdateEngine {
    func modeSummary() async -> String
    func checkForUpdates() async -> UpdateCheckResult
    func latestDownloadURL() async -> URL
    func usesExternalScheduler() async -> Bool
    func supportsInteractiveCheck() async -> Bool
    func performInteractiveCheck() async -> String?
    func presentPreparedUpdate() async -> Bool
    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async
    func installPreparedUpdate() async -> Bool
    func configurationStatus() async -> UpdateEngineStatus
}

final class GitHubReleaseUpdateEngine: AppUpdateEngine {
    private let repoOwner = "ChoSeongmin1128"
    private let repoName = "claude-usage"
    private let modeDescription: String

    init(modeDescription: String = "새 버전이 있으면 다운로드 페이지로 안내합니다") {
        self.modeDescription = modeDescription
    }

    func modeSummary() async -> String {
        modeDescription
    }

    func checkForUpdates() async -> UpdateCheckResult {
        await publishEngineMetadata()
        await MainActor.run {
            UpdateRuntimeState.shared.beginChecking()
        }

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            return await finishCheck(result: .error("잘못된 URL"))
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsage", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return await finishCheck(result: .error("응답 없음"))
            }

            guard httpResponse.statusCode == 200 else {
                let code = httpResponse.statusCode
                let msg = code == 403 ? "요청 한도 초과 (잠시 후 재시도)" : "HTTP \(code)"
                Logger.warning("업데이트 확인 실패: HTTP \(code)")
                return await finishCheck(result: .error(msg))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return await finishCheck(result: .error("응답 파싱 실패"))
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"

            guard remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                Logger.info("최신 버전 사용 중: \(currentVersion)")
                return await finishCheck(result: .upToDate(message: nil))
            }

            guard let zipAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let downloadURLString = zipAsset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                Logger.warning("업데이트 zip 에셋을 찾을 수 없음")
                return await finishCheck(result: .error("다운로드 파일 없음"))
            }

            let releaseNotes = json["body"] as? String ?? ""
            let update = UpdateInfo(
                version: remoteVersion,
                downloadURL: downloadURL,
                releaseNotes: releaseNotes
            )

            Logger.info("새 버전 발견: \(remoteVersion) (현재: \(currentVersion))")
            return await finishCheck(result: .available(update))
        } catch {
            Logger.error("업데이트 확인 오류: \(error.localizedDescription)")
            return await finishCheck(result: .error(error.localizedDescription))
        }
    }

    func latestDownloadURL() async -> URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/ClaudeUsage.zip")!
    }

    func usesExternalScheduler() async -> Bool { false }

    func supportsInteractiveCheck() async -> Bool { false }

    func performInteractiveCheck() async -> String? { nil }

    func presentPreparedUpdate() async -> Bool {
        false
    }

    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async {
        await publishEngineMetadata()
    }

    func installPreparedUpdate() async -> Bool {
        false
    }

    func configurationStatus() async -> UpdateEngineStatus {
        currentConfigurationStatus()
    }

    private func currentConfigurationStatus() -> UpdateEngineStatus {
        UpdateConfigurationInspector.currentStatus()
            .replacing(modeSummary: modeDescription)
    }

    private func publishEngineMetadata() async {
        let engineStatus = currentConfigurationStatus()
        await MainActor.run {
            UpdateRuntimeState.shared.applyEngineStatus(engineStatus)
        }
    }

    private func finishCheck(result: UpdateCheckResult) async -> UpdateCheckResult {
        await MainActor.run {
            switch result {
            case .available(let update):
                UpdateRuntimeState.shared.markUpdateAvailable(update)
            case .upToDate(let message):
                UpdateRuntimeState.shared.markUpToDate(message: message ?? "최신 버전입니다")
            case .error(let message):
                UpdateRuntimeState.shared.markFailed(message: message)
            }
        }

        return result
    }
}

#if canImport(Sparkle)
enum SparkleUpdateResultInterpreter {
    // Sparkle's NSError codes from SUErrors.h are not all surfaced as Swift symbols,
    // so we mirror the stable raw values we actually need here.
    private enum ErrorCode {
        static let insecureFeedURL = 3
        static let invalidFeedURL = 4
        static let appcastParse = 1000
        static let noUpdate = 1001
        static let appcast = 1002
        static let runningFromDiskImage = 1003
        static let runningTranslocated = 1005
        static let download = 2001
    }

    private enum NoUpdateReason {
        static let onLatestVersion = 1
        static let onNewerThanLatestVersion = 2
        static let systemIsTooOld = 3
        static let systemIsTooNew = 4
    }

    static func resolve(error: Error?, fallback: UpdateCheckResult?) -> UpdateCheckResult {
        guard let error else {
            return fallback ?? .upToDate(message: nil)
        }

        let nsError = error as NSError
        Logger.warning("Sparkle 업데이트 확인 종료: domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

        if isNoUpdateError(nsError) {
            return .upToDate(message: upToDateMessage(for: nsError))
        }

        return .error(userFacingMessage(for: nsError) ?? nsError.localizedDescription)
    }

    static func isNoUpdateError(_ error: NSError) -> Bool {
        if error.domain == SUSparkleErrorDomain, error.code == ErrorCode.noUpdate {
            return true
        }

        return error.userInfo[SPUNoUpdateFoundReasonKey] != nil
    }

    private static func upToDateMessage(for error: NSError) -> String {
        let reasonValue = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue

        switch reasonValue {
        case NoUpdateReason.onLatestVersion:
            return "현재 설치본이 최신 버전입니다"
        case NoUpdateReason.onNewerThanLatestVersion:
            return "현재 설치본이 업데이트 채널보다 새 버전입니다"
        case NoUpdateReason.systemIsTooOld:
            return "현재 macOS 버전에서 설치할 수 있는 업데이트가 없습니다"
        case NoUpdateReason.systemIsTooNew:
            return "현재 macOS 버전에 맞는 업데이트가 아직 없습니다"
        default:
            return "현재 설치본이 최신 버전입니다"
        }
    }

    private static func userFacingMessage(for error: NSError) -> String? {
        guard error.domain == SUSparkleErrorDomain else { return nil }

        switch error.code {
        case ErrorCode.runningFromDiskImage, ErrorCode.runningTranslocated:
            return "다운로드한 위치에서 실행 중이라 업데이트할 수 없습니다. 응용 프로그램 폴더로 옮긴 뒤 다시 열어 주세요"
        case ErrorCode.appcastParse, ErrorCode.appcast, ErrorCode.download:
            return "업데이트 정보를 확인하지 못했습니다. 잠시 후 다시 시도하거나 다운로드 페이지에서 설치해 주세요"
        case ErrorCode.insecureFeedURL, ErrorCode.invalidFeedURL:
            return "업데이트 채널 주소가 올바르지 않습니다"
        default:
            return nil
        }
    }
}

@MainActor
final class SparkleUpdateEngine: NSObject, AppUpdateEngine, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(
        // feed override / 자동 확인 설정을 먼저 맞춘 뒤 updater 를 시작해야
        // 첫 scheduled cycle 이 잘못된 기본 appcast 를 보지 않습니다.
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    private let preferredFeedURL: URL?
    private var activeSessionOrigin: UpdateSessionOrigin?
    private var pendingCheckContinuation: CheckedContinuation<UpdateCheckResult, Never>?
    private var lastCycleResult: UpdateCheckResult?
    private var preparedInstallHandler: (() -> Void)?
    private var installRequestInProgress = false
    private var appliedFeedOverrideURL: URL?
    private var hasStartedUpdater = false

    static func makeIfConfigured() -> SparkleUpdateEngine? {
        guard let feedURL = UpdateConfigurationInspector.configuredFeedURL(),
              UpdateConfigurationInspector.configuredValue(for: "SUPublicEDKey") != nil else {
            return nil
        }

        return SparkleUpdateEngine(feedURL: feedURL)
    }

    init(feedURL: URL?) {
        self.preferredFeedURL = feedURL
    }

    func modeSummary() async -> String {
        UpdateEngineMessages.sparkleSchedulerReadyMessage(usingFeedOverride: UpdateConfigurationInspector.usesFeedOverride())
    }

    func checkForUpdates() async -> UpdateCheckResult {
        synchronizeFeedConfiguration(resetCycle: false)
        ensureUpdaterStartedIfNeeded()
        publishEngineMetadata()

        if updater.sessionInProgress {
            return .error(UpdateEngineMessages.updateSessionInProgress)
        }

        activeSessionOrigin = .background
        lastCycleResult = nil
        updater.automaticallyDownloadsUpdates = true
        UpdateRuntimeState.shared.beginChecking(message: "새 버전이 있으면 자동으로 준비합니다")

        return await withCheckedContinuation { continuation in
            pendingCheckContinuation = continuation
            updater.checkForUpdatesInBackground()
        }
    }

    func latestDownloadURL() async -> URL {
        if let update = UpdateRuntimeState.shared.latestKnownUpdate {
            return update.downloadURL
        }
        return URL(string: "https://github.com/ChoSeongmin1128/claude-usage/releases/latest")!
    }

    func usesExternalScheduler() async -> Bool { true }

    func supportsInteractiveCheck() async -> Bool { false }

    func performInteractiveCheck() async -> String? {
        guard AppInstallLocationPolicy.currentAssessment().isStableInstall else {
            UpdateRuntimeState.shared.markFailed(message: "Applications 폴더로 이동한 뒤 업데이트를 확인할 수 있습니다")
            return nil
        }

        synchronizeFeedConfiguration(resetCycle: false)
        ensureUpdaterStartedIfNeeded()
        publishEngineMetadata()
        activeSessionOrigin = .interactive
        lastCycleResult = nil
        updaterController.checkForUpdates(nil)
        return UpdateEngineMessages.sparkleInteractiveStarted
    }

    func presentPreparedUpdate() async -> Bool {
        guard let message = await performInteractiveCheck() else {
            return false
        }
        UpdateRuntimeState.shared.markInteractiveCheckStarted(message: message)
        return true
    }

    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async {
        synchronizeFeedConfiguration(resetCycle: false)

        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = UpdateCheckInterval.enforcedTimerInterval
        updater.automaticallyDownloadsUpdates = true

        ensureUpdaterStartedIfNeeded()
        publishEngineMetadata()

        if runImmediate {
            beginBackgroundCheck(origin: .background)
        }
    }

    func installPreparedUpdate() async -> Bool {
        guard AppInstallLocationPolicy.currentAssessment().isStableInstall else {
            UpdateRuntimeState.shared.markFailed(message: "Applications 폴더로 이동한 뒤 업데이트를 설치할 수 있습니다")
            return false
        }

        guard let handler = preparedInstallHandler else {
            UpdateRuntimeState.shared.markFailed(message: "설치 준비가 만료되었습니다. 업데이트를 다시 확인해 주세요")
            return false
        }

        let version = UpdateRuntimeState.shared.latestKnownUpdate?.version ?? "?"
        guard !installRequestInProgress else {
            requestApplicationTerminationIfInstallerIsWaiting()
            return true
        }

        installRequestInProgress = true
        UpdateRuntimeState.shared.markInstalling(version: version)
        handler()
        requestApplicationTerminationIfInstallerIsWaiting()
        return true
    }

    func configurationStatus() async -> UpdateEngineStatus {
        Self.sparkleConfigurationStatus()
    }

    private var updater: SPUUpdater {
        updaterController.updater
    }

    private static func sparkleConfigurationStatus() -> UpdateEngineStatus {
        UpdateConfigurationInspector.currentStatus().replacing(
            modeSummary: UpdateEngineMessages.sparkleSchedulerReadyMessage(
                usingFeedOverride: UpdateConfigurationInspector.usesFeedOverride()
            )
        )
    }

    private func publishEngineMetadata() {
        synchronizeFeedConfiguration(resetCycle: false)
        UpdateRuntimeState.shared.applyEngineStatus(Self.sparkleConfigurationStatus())
    }

    private func beginBackgroundCheck(origin: UpdateSessionOrigin) {
        synchronizeFeedConfiguration(resetCycle: false)
        ensureUpdaterStartedIfNeeded()
        guard updater.sessionInProgress == false else { return }

        activeSessionOrigin = origin
        lastCycleResult = nil
        updater.automaticallyDownloadsUpdates = true
        UpdateRuntimeState.shared.beginChecking()
        updater.checkForUpdatesInBackground()
    }

    private func updateInfo(for item: SUAppcastItem) -> UpdateInfo {
        let downloadURL = item.fileURL ?? item.infoURL ?? preferredFeedURL ?? URL(string: "https://github.com/ChoSeongmin1128/claude-usage/releases/latest")!
        let releaseNotes = item.itemDescription ?? item.releaseNotesURL?.absoluteString ?? ""

        return UpdateInfo(
            version: item.displayVersionString,
            downloadURL: downloadURL,
            releaseNotes: releaseNotes
        )
    }

    private func resumePendingCheckIfNeeded(with result: UpdateCheckResult) {
        guard let continuation = pendingCheckContinuation else { return }
        pendingCheckContinuation = nil
        continuation.resume(returning: result)
    }

    private func defaultResult(for error: Error?) -> UpdateCheckResult {
        SparkleUpdateResultInterpreter.resolve(error: error, fallback: lastCycleResult)
    }

    private func requestApplicationTerminationIfInstallerIsWaiting() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard case .installing = UpdateRuntimeState.shared.phase else { return }
            Logger.info("Sparkle 업데이트 설치를 위해 앱 종료를 직접 요청합니다")
            NSApplication.shared.terminate(nil)
        }
    }

    private func synchronizeFeedConfiguration(resetCycle: Bool) {
        let usesOverride = UpdateConfigurationInspector.usesFeedOverride()
        let resolvedFeedURL = UpdateConfigurationInspector.configuredFeedURL() ?? preferredFeedURL
        let defaults = UserDefaults.standard
        let persistedFeedOverride = defaults.string(forKey: "SUFeedURL")

        guard let resolvedFeedURL else {
            return
        }

        if usesOverride {
            guard appliedFeedOverrideURL != resolvedFeedURL || persistedFeedOverride != resolvedFeedURL.absoluteString else {
                return
            }

            defaults.set(resolvedFeedURL.absoluteString, forKey: "SUFeedURL")
            appliedFeedOverrideURL = resolvedFeedURL
            Logger.info("Sparkle feed override 적용: \(resolvedFeedURL.absoluteString)")

            if resetCycle {
                updater.resetUpdateCycle()
            }
            return
        }

        guard appliedFeedOverrideURL != nil || persistedFeedOverride != nil else {
            return
        }

        defaults.removeObject(forKey: "SUFeedURL")
        appliedFeedOverrideURL = nil
        if let persistedFeedOverride {
            Logger.info("Sparkle 사용자 기본 feed override 해제: \(persistedFeedOverride)")
        }

        if resetCycle {
            updater.resetUpdateCycle()
        }
    }

    private func ensureUpdaterStartedIfNeeded() {
        guard !hasStartedUpdater else { return }
        updaterController.startUpdater()
        hasStartedUpdater = true
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        let configuredFeedURL = UpdateConfigurationInspector.configuredFeedURL() ?? preferredFeedURL
        return configuredFeedURL?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if activeSessionOrigin == nil {
            activeSessionOrigin = .scheduled
        }

        let update = updateInfo(for: item)
        UpdateRuntimeState.shared.markUpdateAvailable(update)

        let result = UpdateCheckResult.available(update)
        lastCycleResult = result
        resumePendingCheckIfNeeded(with: result)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let result = defaultResult(for: error)
        lastCycleResult = result

        switch result {
        case .available(let update):
            UpdateRuntimeState.shared.markUpdateAvailable(update)
        case .upToDate(let message):
            UpdateRuntimeState.shared.markUpToDate(message: message ?? "최신 버전입니다")
        case .error(let message):
            UpdateRuntimeState.shared.markFailed(message: message)
        }

        resumePendingCheckIfNeeded(with: result)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if activeSessionOrigin == nil {
            activeSessionOrigin = .scheduled
        }

        let update = updateInfo(for: item)
        UpdateRuntimeState.shared.markDownloading(update)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let update = updateInfo(for: item)
        UpdateRuntimeState.shared.markDownloadedReady(
            update,
            message: "v\(update.version) 다운로드 완료, 설치 적용 준비 중"
        )
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        preparedInstallHandler = nil
        installRequestInProgress = false
        let message = error.localizedDescription
        lastCycleResult = .error(message)
        UpdateRuntimeState.shared.markFailed(message: message)
        resumePendingCheckIfNeeded(with: .error(message))
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        preparedInstallHandler = nil
        installRequestInProgress = false
        lastCycleResult = .error(UpdateEngineMessages.downloadCancelled)
        UpdateRuntimeState.shared.markFailed(message: UpdateEngineMessages.downloadCancelled)
        resumePendingCheckIfNeeded(with: .error(UpdateEngineMessages.downloadCancelled))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let update = updateInfo(for: item)
        UpdateRuntimeState.shared.markInstalling(version: update.version)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let update = updateInfo(for: item)
        preparedInstallHandler = immediateInstallHandler
        installRequestInProgress = false
        UpdateRuntimeState.shared.markReadyToInstall(update)
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        false
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Logger.info("Sparkle 업데이트 설치 후 앱 재실행을 시작합니다")
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) { }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) { }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if SparkleUpdateResultInterpreter.isNoUpdateError(error as NSError) {
            return
        }

        preparedInstallHandler = nil
        installRequestInProgress = false
        let result = SparkleUpdateResultInterpreter.resolve(error: error, fallback: lastCycleResult)
        lastCycleResult = result

        switch result {
        case .available(let update):
            UpdateRuntimeState.shared.markUpdateAvailable(update)
        case .upToDate(let message):
            UpdateRuntimeState.shared.markUpToDate(message: message ?? "최신 버전입니다")
        case .error(let message):
            UpdateRuntimeState.shared.markFailed(message: message)
        }

        resumePendingCheckIfNeeded(with: result)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let result = defaultResult(for: error)

        if case .checking = UpdateRuntimeState.shared.phase {
            switch result {
            case .available(let update):
                UpdateRuntimeState.shared.markUpdateAvailable(update)
            case .upToDate(let message):
                UpdateRuntimeState.shared.markUpToDate(message: message ?? "최신 버전입니다")
            case .error(let message):
                UpdateRuntimeState.shared.markFailed(message: message)
            }
        }

        resumePendingCheckIfNeeded(with: result)

        if case .readyToInstall = UpdateRuntimeState.shared.phase {
            return
        }
        activeSessionOrigin = nil
        lastCycleResult = nil
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // 예약 업데이트는 Sparkle 기본 경고창 대신 popover header의 커스텀 버튼으로만 노출합니다.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }

        let updateInfo = updateInfo(for: update)
        switch state.stage {
        case .notDownloaded:
            UpdateRuntimeState.shared.markUpdateAvailable(
                updateInfo,
                message: "v\(updateInfo.version) 업데이트를 자동으로 준비 중"
            )
        case .downloaded:
            switch UpdateRuntimeState.shared.phase {
            case .readyToInstall, .downloaded:
                break
            default:
                UpdateRuntimeState.shared.markDownloadedReady(
                    updateInfo,
                    message: "v\(updateInfo.version) 다운로드 완료, 설치 적용 준비 중"
                )
            }
        case .installing:
            UpdateRuntimeState.shared.markInstalling(version: updateInfo.version)
        @unknown default:
            break
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // 예약 업데이트는 자체 UI로 주의를 끌지 않으므로 별도 후처리는 하지 않습니다.
    }

    func standardUserDriverWillFinishUpdateSession() {
        if case .error = UpdateRuntimeState.shared.phase {
            UpdateRuntimeState.shared.clearTransientError()
        }
    }
}
#endif

enum UpdateConfigurationInspector {
    nonisolated static func currentStatus() -> UpdateEngineStatus {
        #if canImport(Sparkle)
        let feedConfigured = configuredFeedURL() != nil
        let publicKeyConfigured = configuredValue(for: "SUPublicEDKey") != nil
        let summary: String
        if feedConfigured && publicKeyConfigured {
            summary = UpdateEngineMessages.sparkleSchedulerReadyMessage(usingFeedOverride: usesFeedOverride())
        } else {
            summary = UpdateEngineMessages.githubFallback
        }
        return UpdateEngineStatus(
            modeSummary: summary,
            sparkleIntegrated: true,
            feedConfigured: feedConfigured,
            publicKeyConfigured: publicKeyConfigured
        )
        #else
        return UpdateEngineStatus(
            modeSummary: UpdateEngineMessages.githubFallback,
            sparkleIntegrated: false,
            feedConfigured: false,
            publicKeyConfigured: false
        )
        #endif
    }

    #if canImport(Sparkle)
    nonisolated static func configuredValue(for key: String) -> String? {
        if key == "SUFeedURL", let overrideValue = configuredFeedURLOverrideValue() {
            return overrideValue
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("$("), !trimmed.contains("${") else { return nil }
        let lowered = trimmed.lowercased()
        let blockedPlaceholders = ["change_me", "placeholder", "your_public_key", "your_feed_url", "example.com/appcast.xml"]
        guard !blockedPlaceholders.contains(where: { lowered.contains($0) }) else { return nil }
        return trimmed
    }

    nonisolated static func usesFeedOverride() -> Bool {
        configuredFeedURLOverrideValue() != nil
    }

    nonisolated private static func configuredFeedURLOverrideValue() -> String? {
        let environmentOverride = ProcessInfo.processInfo.environment["CLAUDEUSAGE_UPDATE_FEED_URL_OVERRIDE"]
        let defaultsOverride = UserDefaults.standard.string(forKey: "UpdateFeedURLOverride")

        for candidate in [environmentOverride, defaultsOverride] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.contains("$("), !trimmed.contains("${") else { continue }
            let lowered = trimmed.lowercased()
            let blockedPlaceholders = ["change_me", "placeholder", "your_feed_url", "example.com/appcast.xml"]
            guard !blockedPlaceholders.contains(where: { lowered.contains($0) }) else { continue }
            return trimmed
        }

        return nil
    }

    nonisolated static func configuredFeedURL() -> URL? {
        guard let feedURLString = configuredValue(for: "SUFeedURL"),
              let feedURL = URL(string: feedURLString),
              let scheme = feedURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return feedURL
    }

    nonisolated static func engineConfigurationSignature() -> String {
        let feedURL = configuredFeedURL()?.absoluteString ?? "nil"
        let publicKey = configuredValue(for: "SUPublicEDKey") ?? "nil"
        return "\(feedURL)|\(publicKey)"
    }
    #endif
}

enum UpdateEngineFactory {
    static func makeDefaultEngine() async -> any AppUpdateEngine {
        #if canImport(Sparkle)
        if let sparkleEngine = await MainActor.run(body: {
            SparkleUpdateEngine.makeIfConfigured()
        }) {
            return sparkleEngine
        }

        return GitHubReleaseUpdateEngine(
            modeDescription: UpdateEngineMessages.githubFallback
        )
        #else
        return GitHubReleaseUpdateEngine()
        #endif
    }
}

actor UpdateService {
    static let shared = UpdateService()

    private var engine: (any AppUpdateEngine)?
    private var engineConfigurationSignature: String?

    init(engine: (any AppUpdateEngine)? = nil) {
        self.engine = engine
        #if canImport(Sparkle)
        self.engineConfigurationSignature = engine.map { _ in UpdateConfigurationInspector.engineConfigurationSignature() }
        #endif
    }

    private func resolvedEngine() async -> any AppUpdateEngine {
        #if canImport(Sparkle)
        let currentConfigurationSignature = UpdateConfigurationInspector.engineConfigurationSignature()
        if let engine, engineConfigurationSignature == currentConfigurationSignature {
            return engine
        }
        #else
        if let engine {
            return engine
        }
        #endif

        let resolved = await UpdateEngineFactory.makeDefaultEngine()
        engine = resolved
        #if canImport(Sparkle)
        engineConfigurationSignature = currentConfigurationSignature
        #endif
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

    func presentPreparedUpdate() async -> Bool {
        let engine = await resolvedEngine()
        return await engine.presentPreparedUpdate()
    }

    func performUserInitiatedCheck() async {
        let engine = await resolvedEngine()

        if await engine.supportsInteractiveCheck() {
            if let message = await engine.performInteractiveCheck() {
                await MainActor.run {
                    UpdateRuntimeState.shared.markInteractiveCheckStarted(message: message)
                }
            }
            return
        }

        _ = await engine.checkForUpdates()
    }

    func performScheduledCheck() async {
        _ = await checkForUpdates()
    }

    func synchronizeScheduler(interval: UpdateCheckInterval, runImmediate: Bool) async {
        let engine = await resolvedEngine()
        await engine.synchronizeScheduler(interval: interval, runImmediate: runImmediate)
    }

    func configureAutomaticChecks(interval: UpdateCheckInterval, runImmediate: Bool) async -> Bool {
        await synchronizeScheduler(interval: interval, runImmediate: runImmediate)
        return await usesExternalScheduler()
    }

    func installPreparedUpdate() async -> Bool {
        let engine = await resolvedEngine()
        return await engine.installPreparedUpdate()
    }

    func currentEngineStatus() async -> UpdateEngineStatus {
        let engine = await resolvedEngine()
        let configuration = UpdateConfigurationInspector.currentStatus()
        return UpdateEngineStatus(
            modeSummary: await engine.modeSummary(),
            sparkleIntegrated: configuration.sparkleIntegrated,
            feedConfigured: configuration.feedConfigured,
            publicKeyConfigured: configuration.publicKeyConfigured
        )
    }
}
