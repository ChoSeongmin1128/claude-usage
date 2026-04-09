import AppKit

enum AppLocationChecker {
    private static let suppressionKey = "suppressMoveToApplicationsAlert"

    static func checkAndPromptIfNeeded() {
        // App Translocation 상태면 경로 판단이 불가하므로 건너뜀
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/private/var/folders/") {
            return
        }

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

    /// App Translocation을 고려한 실제 앱 경로를 반환합니다.
    private static func originalBundlePath() -> String {
        let bundlePath = Bundle.main.bundlePath

        // App Translocation 감지
        if bundlePath.contains("/AppTranslocation/") || bundlePath.contains("/private/var/folders/") {
            // Finder의 원래 경로를 bookmark에서 복원
            let bundleURL = URL(fileURLWithPath: bundlePath)
            if let resolved = try? URL(resolvingAliasFileAt: bundleURL, options: [.withoutUI, .withoutMounting]) {
                let resolvedPath = resolved.path
                if resolvedPath != bundlePath {
                    return resolvedPath
                }
            }
        }

        return bundlePath
    }

    private static func isInApplicationsFolder() -> Bool {
        let bundlePath = originalBundlePath()
        let applicationsDirectories = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]
        return applicationsDirectories.contains { bundlePath.hasPrefix($0 + "/") }
    }

    private static func moveToApplicationsFolder() {
        let source = originalBundlePath()
        let appName = (source as NSString).lastPathComponent
        let destination = "/Applications/\(appName)"

        // translocation 상태인데 원본 경로를 못 찾으면 중단
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") && source == bundlePath {
            showError("macOS가 앱을 임시 위치에서 실행 중입니다.\n먼저 Finder에서 앱을 한 번 이동(예: 바탕화면으로)한 뒤 다시 실행해 주세요.")
            return
        }

        let fm = FileManager.default

        if fm.fileExists(atPath: destination) {
            do {
                try fm.removeItem(atPath: destination)
            } catch {
                showError("기존 앱 제거 실패: \(error.localizedDescription)")
                return
            }
        }

        do {
            try fm.moveItem(atPath: source, toPath: destination)
        } catch {
            do {
                try fm.copyItem(atPath: source, toPath: destination)
                try? fm.removeItem(atPath: source)
            } catch {
                showError("앱 이동 실패: \(error.localizedDescription)")
                return
            }
        }

        // quarantine 속성 제거 (removexattr C API — sandbox에서도 동작)
        removeQuarantineRecursively(at: destination)

        // 현재 앱 종료 후 새 위치에서 재시작 (지연 실행으로 종료 후 open)
        let script = "sleep 1 && open \"\(destination)\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()

        NSApp.terminate(nil)
    }

    private static func removeQuarantineRecursively(at path: String) {
        removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return }
        while let relative = enumerator.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            removexattr(full, "com.apple.quarantine", XATTR_NOFOLLOW)
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
