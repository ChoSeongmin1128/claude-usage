import Foundation

@MainActor
final class AppUpdateCoordinator {
    private var timer: Timer?

    func apply(
        interval: UpdateCheckInterval,
        runImmediate: Bool,
        performCheck: @escaping () -> Void
    ) {
        timer?.invalidate()
        timer = nil

        if runImmediate {
            performCheck()
        }

        guard let seconds = interval.timerInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            performCheck()
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}
