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

    @Published private(set) var modeSummary: String = "업데이트 엔진 확인 중"
    @Published private(set) var engineStatus: UpdateEngineStatus?
    @Published private(set) var supportsInteractiveUpdates = false
    @Published private(set) var usesExternalScheduler = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var nextScheduledCheckAt: Date?
    @Published private(set) var latestKnownUpdate: UpdateInfo?
    @Published private(set) var lastCheckMessage: String?
    @Published private(set) var lastErrorMessage: String?

    private let settings: AppSettings
    private var installHandler: (() -> Void)?
    private var didBootstrap = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.latestKnownUpdate = settings.availableUpdate
        if let update = settings.availableUpdate {
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

    var statusTitle: String {
        switch phase {
        case .checking:
            return "업데이트 확인 중"
        case .interactiveCheckStarted:
            return "설치 확인 창을 열었습니다"
        case .updateAvailable(let version):
            return "v\(version) 업데이트 가능"
        case .downloading(let version):
            return "v\(version) 자동 다운로드 중"
        case .downloaded(let version):
            return "v\(version) 설치 준비됨"
        case .readyToInstall(let version):
            return "v\(version) 설치 준비 완료"
        case .installing(let version):
            return "v\(version) 설치 적용 중"
        case .upToDate:
            return "최신 버전 사용 중"
        case .error:
            return "업데이트 확인 실패"
        case .idle:
            if engineStatus?.usesSparkleReadyPath == true {
                return "자동 업데이트 준비됨"
            }
            return "업데이트 채널 점검 필요"
        }
    }

    var statusSummary: String {
        switch phase {
        case .checking:
            return "현재 버전과 업데이트 채널을 비교하고 있습니다."
        case .interactiveCheckStarted:
            return "열린 확인 창에서 설치를 이어서 진행할 수 있습니다."
        case .updateAvailable:
            if engineStatus?.usesSparkleReadyPath == true {
                return "새 버전이 감지됐습니다. 자동 다운로드가 진행되면 설치 준비 상태로 전환됩니다."
            }
            return "새 버전을 내려받아 기존 앱을 교체 설치할 수 있습니다."
        case .downloading:
            return "새 버전을 백그라운드에서 내려받고 있습니다."
        case .downloaded:
            return "다운로드와 검증이 끝났습니다. 버튼을 눌러 설치 화면을 바로 열 수 있습니다."
        case .readyToInstall:
            return "다운로드와 검증이 끝났습니다. 원할 때 바로 설치를 적용할 수 있습니다."
        case .installing:
            return "설치를 진행 중입니다. 앱이 다시 열리면 새 버전이 적용됩니다."
        case .upToDate:
            return lastCheckMessage ?? "현재 설치본이 최신 버전입니다."
        case .error(let message):
            return message
        case .idle:
            if engineStatus?.usesSparkleReadyPath == true {
                return "새 버전이 있으면 자동으로 내려받고 준비되면 알려드립니다."
            }
            return "새 버전이 있으면 다운로드 페이지로 안내합니다."
        }
    }

    var statusDetail: String? {
        switch phase {
        case .readyToInstall:
            return "popover header의 파란 버튼이나 아래 기본 액션으로 바로 설치를 적용할 수 있습니다."
        case .downloaded:
            return "popover header의 파란 버튼이나 아래 기본 액션으로 Sparkle 설치 화면을 바로 열 수 있습니다."
        case .downloading:
            return "다운로드 중에는 새 업데이트 확인을 다시 실행하지 않습니다."
        case .installing:
            return "설치 중에는 잠시 후 앱이 다시 실행될 수 있습니다."
        case .interactiveCheckStarted:
            return "열린 확인 창에서 설치 여부를 선택해 주세요."
        default:
            return nil
        }
    }

    var currentVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version)"
    }

    var releaseNotesPreview: String? {
        guard let releaseNotes = latestKnownUpdate?.releaseNotes else { return nil }
        let plain = Self.stripMarkup(from: releaseNotes)
        let lines = plain
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(3).joined(separator: "\n")
    }

    var showsPopoverButton: Bool {
        guard engineStatus?.usesSparkleReadyPath == true else { return false }
        switch phase {
        case .downloaded, .readyToInstall:
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
        case .downloaded, .readyToInstall:
            return "지금 설치"
        case .downloading:
            return "다운로드 중"
        case .updateAvailable:
            return "다운로드"
        default:
            return "지금 확인"
        }
    }

    var showsPrimaryAction: Bool {
        switch phase {
        case .downloaded, .readyToInstall, .downloading:
            return true
        case .updateAvailable:
            return engineStatus?.usesSparkleReadyPath != true
        default:
            return false
        }
    }

    var isPrimaryActionEnabled: Bool {
        switch phase {
        case .downloading, .installing:
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
            let modeSummary = await UpdateService.shared.currentModeSummary()
            let engineStatus = await UpdateService.shared.currentEngineStatus()
            let supportsInteractive = await UpdateService.shared.supportsInteractiveCheck()
            let usesExternalScheduler = await UpdateService.shared.usesExternalScheduler()
            await MainActor.run {
                self.applyEngineMetadata(
                    modeSummary: modeSummary,
                    engineStatus: engineStatus,
                    supportsInteractive: supportsInteractive,
                    usesExternalScheduler: usesExternalScheduler
                )
            }
        }
    }

    func checkNow() {
        Task {
            await UpdateService.shared.performUserInitiatedCheck()
        }
    }

    func performPrimaryAction() {
        switch phase {
        case .readyToInstall:
            guard let installHandler else { return }
            let version = latestKnownUpdate?.version ?? "?"
            self.installHandler = nil
            phase = .installing(version: version)
            lastCheckMessage = "v\(version) 설치 적용 중"
            lastErrorMessage = nil
            installHandler()
        case .downloaded:
            checkNow()
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

    func openLatestReleasePage() {
        Task {
            let url = await UpdateService.shared.latestDownloadURL()
            NSWorkspace.shared.open(url)
        }
    }

    func applyEngineMetadata(
        modeSummary: String,
        engineStatus: UpdateEngineStatus,
        supportsInteractive: Bool,
        usesExternalScheduler: Bool
    ) {
        self.modeSummary = modeSummary
        self.engineStatus = engineStatus
        self.supportsInteractiveUpdates = supportsInteractive
        self.usesExternalScheduler = usesExternalScheduler
    }

    func beginChecking(message: String? = nil) {
        phase = .checking
        lastCheckMessage = message
        lastErrorMessage = nil
        installHandler = nil
    }

    func markInteractiveCheckStarted(message: String) {
        phase = .interactiveCheckStarted
        lastCheckedAt = Date()
        lastCheckMessage = message
        lastErrorMessage = nil
        installHandler = nil
    }

    func markUpdateAvailable(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .updateAvailable(version: update.version)
        lastCheckedAt = Date()
        lastCheckMessage = message ?? "v\(update.version) 업데이트 가능"
        lastErrorMessage = nil
        installHandler = nil
    }

    func markDownloading(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .downloading(version: update.version)
        lastCheckedAt = Date()
        lastCheckMessage = message ?? "v\(update.version) 다운로드 중"
        lastErrorMessage = nil
    }

    func markDownloadedReady(_ update: UpdateInfo, message: String? = nil) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        phase = .downloaded(version: update.version)
        lastCheckedAt = Date()
        lastCheckMessage = message ?? "v\(update.version) 다운로드 완료"
        lastErrorMessage = nil
        installHandler = nil
    }

    func markReadyToInstall(_ update: UpdateInfo, installHandler: @escaping () -> Void) {
        latestKnownUpdate = update
        settings.availableUpdate = update
        self.installHandler = installHandler
        phase = .readyToInstall(version: update.version)
        lastCheckedAt = Date()
        lastCheckMessage = "v\(update.version) 설치 준비 완료"
        lastErrorMessage = nil
    }

    func markInstalling(version: String) {
        phase = .installing(version: version)
        lastCheckMessage = "v\(version) 설치 적용 중"
        lastErrorMessage = nil
    }

    func markUpToDate(message: String = "최신 버전입니다") {
        latestKnownUpdate = nil
        settings.availableUpdate = nil
        phase = .upToDate
        lastCheckedAt = Date()
        lastCheckMessage = message
        lastErrorMessage = nil
        installHandler = nil
    }

    func markFailed(message: String) {
        phase = .error(message: message)
        lastCheckedAt = Date()
        lastErrorMessage = message
        if latestKnownUpdate == nil {
            lastCheckMessage = nil
        }
        installHandler = nil
    }

    func clearTransientError() {
        if case .error = phase, latestKnownUpdate == nil {
            phase = .idle
        }
        lastErrorMessage = nil
    }

    func setNextScheduledCheck(after delay: TimeInterval) {
        nextScheduledCheckAt = Date().addingTimeInterval(delay)
    }

    func clearScheduledCheck() {
        nextScheduledCheckAt = nil
    }

    private static func stripMarkup(from text: String) -> String {
        let withoutTags = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
