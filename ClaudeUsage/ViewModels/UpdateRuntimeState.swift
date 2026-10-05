import AppKit
import Combine
import Foundation

@MainActor
final class UpdateRuntimeState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case interactiveCheckStarted
        case updateAvailable(version: String)
        case downloading(version: String)
        case downloaded(version: String)
        case readyToInstall(version: String)
        case installing(version: String)
        case upToDate
        case error(message: String)
    }

    enum Tone {
        case accent
        case positive
        case caution
        case destructive
        case secondary
    }

    static let shared = UpdateRuntimeState()

    @Published private(set) var engineStatus: UpdateEngineStatus?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latestKnownUpdate: UpdateInfo?
    @Published private(set) var lastCheckMessage: String?

    private let settings: AppSettings
    private let updateService: UpdateService
    private var didBootstrap = false

    init(settings: AppSettings? = nil, updateService: UpdateService = .shared) {
        self.updateService = updateService
        self.settings = settings ?? .shared
        self.latestKnownUpdate = self.settings.availableUpdate
        if let update = self.settings.availableUpdate {
            self.phase = .updateAvailable(version: update.version)
            self.lastCheckMessage = "v\(update.version) 업데이트 가능"
        }
    }

    var isChecking: Bool {
        switch phase {
        case .checking:
            return true
        default:
            return false
        }
    }

    var tone: Tone {
        switch phase {
        case .checking, .installing:
            return .secondary
        case .updateAvailable, .downloading, .downloaded, .readyToInstall:
            return .accent
        case .interactiveCheckStarted, .upToDate:
            return .positive
        case .error:
            return .destructive
        case .idle:
            return engineStatus?.usesSparkleReadyPath == true ? .positive : .caution
        }
    }

    /// 지금 상태 한 줄. 할 일이나 알릴 것이 없으면 없다.
    var statusSummary: String? {
        switch phase {
        case .checking: return "확인 중"
        case .interactiveCheckStarted: return "확인 창에서 설치를 계속하세요."
        case .updateAvailable: return "새 버전이 있습니다."
        case .downloading: return "내려받는 중"
        case .downloaded: return "설치 준비 중"
        case .readyToInstall: return "설치 준비됨"
        case .installing: return "설치 중입니다. 앱이 다시 열립니다."
        case .upToDate: return lastCheckMessage ?? "최신 버전입니다."
        case .error(let message): return message
        case .idle: return nil
        }
    }

    var currentVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return AppDistribution.current.versionLabel(
            version: version,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            releaseVersion: Bundle.main.object(forInfoDictionaryKey: AppIdentifiers.releaseVersionInfoKey) as? String)
    }

    var showsPopoverButton: Bool {
        Self.shouldShowPopoverButton(phase: phase, engineStatus: engineStatus)
    }

    nonisolated static func shouldShowPopoverButton(phase: Phase, engineStatus: UpdateEngineStatus?) -> Bool {
        guard engineStatus?.usesSparkleReadyPath == true else { return false }
        switch phase {
        case .readyToInstall:
            return true
        default:
            return false
        }
    }

    var popoverButtonSymbolName: String {
        switch phase {
        case .downloaded:
            return "arrow.down.circle.fill"
        case .readyToInstall:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        default:
            return "arrow.down.circle"
        }
    }

    var popoverButtonHelpText: String {
        switch phase {
        case .downloading(let version):
            return "v\(version) 업데이트 다운로드 중"
        case .downloaded(let version):
            return "v\(version) 설치 화면 열기"
        case .readyToInstall(let version):
            return "v\(version) 지금 설치"
        default:
            if let update = latestKnownUpdate {
                return "v\(update.version) 업데이트 다운로드"
            }
            return "업데이트 확인"
        }
    }

    var primaryActionTitle: String {
        switch phase {
        case .readyToInstall:
            return "지금 설치"
        case .installing:
            return "재실행"
        case .downloaded:
            return "설치 준비 중"
        case .downloading:
            return "다운로드 중"
        case .updateAvailable:
            return "다운로드"
        default:
            return "지금 확인"
        }
    }

    var showsPrimaryAction: Bool {
        Self.shouldShowPrimaryAction(phase: phase, engineStatus: engineStatus)
    }

    nonisolated static func shouldShowPrimaryAction(phase: Phase, engineStatus: UpdateEngineStatus?) -> Bool {
        switch phase {
        case .readyToInstall, .downloading, .installing:
            return true
        case .updateAvailable:
            return engineStatus?.usesSparkleReadyPath != true
        default:
            return false
        }
    }

    var isPrimaryActionEnabled: Bool {
        switch phase {
        case .downloading:
            return false
        default:
            return true
        }
    }

    var canCheckNow: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return false
        default:
            return true
        }
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshEngineStatus()
    }

    func refreshEngineStatus() {
        Task {
            let engineStatus = await self.updateService.currentEngineStatus()
            await MainActor.run {
                self.engineStatus = engineStatus
            }
        }
    }

    func checkNow() {
        Task {
            await self.updateService.performUserInitiatedCheck()
        }
    }

    func performPrimaryAction() {
        switch phase {
        case .readyToInstall:
            Task {
                await self.updateService.installPreparedUpdate()
            }
        case .installing:
            NSApplication.shared.terminate(nil)
        case .updateAvailable:
            if let update = latestKnownUpdate {
                NSWorkspace.shared.open(update.downloadURL)
            }
        case .downloading:
            break
        default:
            checkNow()
        }
    }

    func applyEngineStatus(_ engineStatus: UpdateEngineStatus) {
        self.engineStatus = engineStatus
    }

    func beginChecking(message: String? = nil) {
        phase = .checking
        lastCheckMessage = message
    }

    func markInteractiveCheckStarted(message: String) {
        phase = .interactiveCheckStarted
        lastCheckMessage = message
    }

    func markUpdateAvailable(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .updateAvailable(version: update.version)
        lastCheckMessage = message ?? "v\(update.version) 업데이트 가능"
    }

    func markDownloading(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .downloading(version: update.version)
        lastCheckMessage = message ?? "v\(update.version) 다운로드 중"
    }

    func markDownloadedReady(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .downloaded(version: update.version)
        lastCheckMessage = message ?? "v\(update.version) 다운로드 완료"
    }

    func markReadyToInstall(_ update: UpdateInfo) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .readyToInstall(version: update.version)
        lastCheckMessage = "v\(update.version) 설치 준비 완료"
    }

    func markInstalling(version: String) {
        phase = .installing(version: version)
        lastCheckMessage = "v\(version) 설치 적용 중"
    }

    func markUpToDate(message: String = "최신 버전입니다") {
        latestKnownUpdate = nil
        settings.availableUpdate = nil
        phase = .upToDate
        lastCheckMessage = message
    }

    func markFailed(message: String) {
        phase = .error(message: message)
        if latestKnownUpdate == nil {
            lastCheckMessage = nil
        }
    }

    func clearTransientError() {
        if case .error = phase, latestKnownUpdate == nil {
            phase = .idle
        }
    }
}
