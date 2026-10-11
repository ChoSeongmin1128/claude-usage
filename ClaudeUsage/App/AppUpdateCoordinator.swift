import Foundation

@MainActor
final class AppUpdateCoordinator {
    private var timer: Timer?

    func apply(
        interval: UpdateCheckInterval,
        runImmediate: Bool,
        performCheck: @escaping @MainActor @Sendable () -> Void
    ) {
        timer?.invalidate()
        timer = nil

        if runImmediate {
            performCheck()
        }

        guard let seconds = interval.timerInterval else { return }
        timer = Timer.scheduledOnMainRunLoop(interval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated { performCheck() }
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
