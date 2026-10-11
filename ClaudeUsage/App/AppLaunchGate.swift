import AppKit

/// 같은 채널의 두 번째 실행은 설정, 계정 자료, 이전 자료 정리를 만지기 전에 끝낸다.
enum AppLaunchGate {
    private(set) static var ownsLease = false

    static func acquireOrExit() {
        guard !AppRuntimeEnvironment.isRunningUnitTests else { return }
        switch AppSingleInstanceGuard.shared.acquire(
            applicationSupportDirectoryURL: AntigravityStoragePaths.applicationSupportDirectoryURL()
        ) {
        case .acquired:
            ownsLease = true
        case .alreadyRunning:
            Logger.warning("\(AppDistribution.current.appName) 동일 채널 인스턴스가 이미 실행 중입니다.")
            activateExistingInstance()
            exit(0)
        case .failed(let code):
            Logger.error("단일 인스턴스 잠금을 만들지 못했습니다: \(code)")
            exit(1)
        }
    }

    private static func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != current && !$0.isTerminated }?
            .activate()
    }
}
