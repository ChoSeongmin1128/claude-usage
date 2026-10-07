import Foundation
import ServiceManagement

nonisolated enum LoginItemStatus: Equatable, Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unknown

    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
    func fulfills(_ enabled: Bool) -> Bool { enabled ? isRegistered : self == .notRegistered }
}

nonisolated struct LaunchAtLoginState: Equatable, Sendable {
    enum Action: Equatable, Sendable { case enable, disable }
    struct Failure: Equatable, Sendable {
        let action: Action
        let code: Int?
    }

    let status: LoginItemStatus
    var failure: Failure? = nil

    var isEnabled: Bool { status == .enabled }
    /// Approval is a registered request, not permission to run yet.
    var isSelected: Bool { status.isRegistered }
    var requiresApproval: Bool { status == .requiresApproval }
    var canOpenSystemSettings: Bool { requiresApproval || failure != nil || status == .notFound || status == .unknown }

    var notice: String? {
        if let failure {
            return failure.action == .enable
                ? "자동 시작을 등록하지 못했습니다. 시스템 설정에서 확인해 주세요."
                : "자동 시작을 해제하지 못했습니다. 시스템 설정에서 확인해 주세요."
        }
        switch status {
        case .requiresApproval: return "승인이 필요합니다. 시스템 설정에서 허용하면 로그인 시 실행됩니다."
        case .notFound: return "macOS에서 이 앱의 로그인 항목을 찾지 못했습니다."
        case .unknown: return "로그인 항목 상태를 확인하지 못했습니다."
        case .enabled, .notRegistered: return nil
        }
    }
}

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct SystemLoginItemService: LoginItemManaging {
    private var service: SMAppService { SMAppService.mainApp }
    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Owns system commands. Presentation and the legacy saved Boolean are separate projections.
@MainActor
final class LaunchAtLoginController {
    private let service: any LoginItemManaging
    init(service: any LoginItemManaging = SystemLoginItemService()) { self.service = service }

    func initialState() -> LaunchAtLoginState { .init(status: service.status) }

    func request(_ enabled: Bool) -> LaunchAtLoginState {
        let started = ContinuousClock.now
        let action: LaunchAtLoginState.Action = enabled ? .enable : .disable
        var errorCode: Int?
        let before = service.status
        do {
            if enabled, !before.isRegistered {
                try service.register()
            } else if !enabled, before.isRegistered {
                try service.unregister()
            }
        } catch { errorCode = (error as NSError).code }
        let status = service.status
        let accepted = status.fulfills(enabled)
        let failure: LaunchAtLoginState.Failure? = accepted ? nil : .init(action: action, code: errorCode)
        let state = LaunchAtLoginState(status: status, failure: failure)
        OperationalLog.record(.launchAtLogin(state), elapsed: started.duration(to: .now))
        return state
    }

    func refresh(_ previous: LaunchAtLoginState) -> LaunchAtLoginState {
        let status = service.status
        let failure = previous.failure.flatMap { failure in
            status.fulfills(failure.action == .enable) ? nil : failure
        }
        return .init(status: status, failure: failure)
    }

    func openSystemSettings() { service.openSystemSettings() }
}
