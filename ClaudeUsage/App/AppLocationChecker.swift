import AppKit

enum AppLocationChecker {
    private static let suppressionKey = "suppressMoveToApplicationsAlert"

    static func checkAndPromptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: suppressionKey) else { return }
        guard !isInApplicationsFolder() else { return }

        let alert = NSAlert()
        alert.messageText = "Applications 폴더로 이동할까요?"
        alert.informativeText = "앱을 Applications 폴더로 이동하면 안정적으로 사용할 수 있습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Applications으로 이동")
        alert.addButton(withTitle: "이동하지 않음")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "다시 묻지 않기"

        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressionKey)
        }

        if response == .alertFirstButtonReturn {
            moveToApplicationsFolder()
        }
    }

    private static func isInApplicationsFolder() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        let applicationsDirectories = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        return applicationsDirectories.contains { bundlePath.hasPrefix($0 + "/") }
    }

    private static func moveToApplicationsFolder() {
        let source = Bundle.main.bundlePath
        let appName = (source as NSString).lastPathComponent
        let destination = "/Applications/\(appName)"

        let fm = FileManager.default

        // 기존 앱이 있으면 제거
        if fm.fileExists(atPath: destination) {
            do {
                try fm.removeItem(atPath: destination)
            } catch {
                showError("기존 앱 제거 실패: \(error.localizedDescription)")
                return
            }
        }

        do {
            try fm.copyItem(atPath: source, toPath: destination)
        } catch {
            showError("앱 복사 실패: \(error.localizedDescription)")
            return
        }

        // 새 위치에서 앱 재시작
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", destination]
        try? task.run()

        // 현재 앱 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "이동 실패"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
