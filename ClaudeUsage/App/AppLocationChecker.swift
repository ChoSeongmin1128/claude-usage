import AppKit

@MainActor
enum AppLocationChecker {
    static func checkAndPromptIfNeeded() {
        let assessment = AppInstallLocationPolicy.currentAssessment()
        Logger.info("앱 실행 위치: \(assessment.bundlePath) (\(assessment.kind.rawValue))")
        guard assessment.requiresMovePrompt else {
            promptToTrashMountedInstallerDiskImageForStableInstallIfNeeded(assessment)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Applications 폴더로 이동할까요?"
        alert.informativeText = "\(assessment.locationDescription)에서 실행 중이면 자동 업데이트와 재실행이 불안정할 수 있습니다. 이동에 실패해도 현재 앱은 종료하지 않습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Applications으로 이동")
        alert.addButton(withTitle: "이동하지 않음")
        alert.showsSuppressionButton = false

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            moveToApplicationsFolder(from: assessment)
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

    private static func moveToApplicationsFolder(from assessment: AppInstallLocationAssessment) {
        let source = originalBundlePath()
        let sourceAssessment = AppInstallLocationPolicy.assess(bundlePath: source)
        let sourceDiskImage = mountedDiskImageSource(for: source)
            ?? mountedDiskImageSource(for: assessment.bundlePath)
            ?? mountedDiskImageSourceForTranslocatedApp(
                appName: (source as NSString).lastPathComponent,
                sourceAssessment: sourceAssessment,
                runtimeAssessment: assessment
            )
        let appName = (source as NSString).lastPathComponent
        let destinationCandidates = [
            "/Applications/\(appName)",
            "\(NSHomeDirectory())/Applications/\(appName)",
        ]

        guard terminateSiblingApplicationsBeforeMoveIfNeeded() else { return }

        for destination in destinationCandidates {
            do {
                try installAppBundleSafely(
                    from: source,
                    to: destination,
                    strategy: sourceAssessment.preferredTransferStrategy
                )
                launchMovedApp(at: destination, sourceDiskImage: sourceDiskImage)
                return
            } catch {
                Logger.warning("앱 이동 실패(\(destination)): \(error.localizedDescription)")
            }
        }

        showError(
            "자동 이동에 실패했습니다. 현재 앱은 계속 실행됩니다.\n\n"
                + "기존 앱이 열려 있다면 종료한 뒤 다시 시도하거나, Finder에서 ClaudeUsage.app을 Applications 폴더로 직접 옮겨 주세요."
        )
    }

    private static func installAppBundleSafely(
        from source: String,
        to destination: String,
        strategy: AppInstallTransferStrategy
    ) throws {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: source).standardizedFileURL
        let destinationURL = URL(fileURLWithPath: destination).standardizedFileURL
        guard sourceURL.path != destinationURL.path else { return }

        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let tempURL = destinationDirectory.appendingPathComponent(".\(destinationURL.lastPathComponent).installing.\(UUID().uuidString)")
        let backupURL = destinationDirectory.appendingPathComponent(".\(destinationURL.lastPathComponent).backup.\(UUID().uuidString)")

        try? fm.removeItem(at: tempURL)
        switch strategy {
        case .moveSource:
            try fm.moveItem(at: sourceURL, to: tempURL)
        case .copySource:
            try fm.copyItem(at: sourceURL, to: tempURL)
        }
        removeQuarantineRecursively(at: tempURL.path)

        var didCreateBackup = false
        var tempContainsInstallCandidate = true
        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.moveItem(at: destinationURL, to: backupURL)
                didCreateBackup = true
            }
            try fm.moveItem(at: tempURL, to: destinationURL)
            tempContainsInstallCandidate = false
            if didCreateBackup {
                try? fm.removeItem(at: backupURL)
            }
        } catch {
            if didCreateBackup, !fm.fileExists(atPath: destinationURL.path), fm.fileExists(atPath: backupURL.path) {
                try? fm.moveItem(at: backupURL, to: destinationURL)
            }
            if strategy == .moveSource, tempContainsInstallCandidate, !fm.fileExists(atPath: sourceURL.path) {
                try? fm.moveItem(at: tempURL, to: sourceURL)
                tempContainsInstallCandidate = false
            }
            if tempContainsInstallCandidate {
                try? fm.removeItem(at: tempURL)
            }
            throw error
        }
    }

    private static func launchMovedApp(at destination: String, sourceDiskImage: AppDiskImageSource?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: destination), configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Logger.warning("새 위치 앱 실행 실패: \(error.localizedDescription)")
                    showError("새 위치로 이동했지만 실행하지 못했습니다. 현재 앱은 계속 실행됩니다.\n\nApplications 폴더에서 ClaudeUsage.app을 직접 열어 주세요.")
                    return
                }
                promptToTrashSourceDiskImageIfNeeded(sourceDiskImage)
                NSApp.terminate(nil)
            }
        }
    }

    private static func mountedDiskImageSource(for bundlePath: String) -> AppDiskImageSource? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return AppInstallLocationPolicy.diskImageSource(for: bundlePath, hdiutilInfoPlistData: data)
        } catch {
            Logger.warning("DMG 원본 조회 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private static func mountedDiskImageSourceForTranslocatedApp(
        appName: String,
        sourceAssessment: AppInstallLocationAssessment,
        runtimeAssessment: AppInstallLocationAssessment
    ) -> AppDiskImageSource? {
        guard sourceAssessment.kind == .appTranslocation
            || sourceAssessment.kind == .temporary
            || runtimeAssessment.kind == .appTranslocation
            || runtimeAssessment.kind == .temporary
        else {
            return nil
        }

        return mountedDiskImageSourceForAppBundle(appName: appName)
    }

    private static func mountedDiskImageSourceForAppBundle(appName: String) -> AppDiskImageSource? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return AppInstallLocationPolicy.diskImageSource(
                forAppNamed: appName,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                hdiutilInfoPlistData: data
            ) { candidatePath in
                Bundle(url: URL(fileURLWithPath: candidatePath))?.bundleIdentifier
            }
        } catch {
            Logger.warning("DMG 설치 파일 조회 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private static func promptToTrashMountedInstallerDiskImageForStableInstallIfNeeded(
        _ assessment: AppInstallLocationAssessment
    ) {
        guard assessment.isStableInstall else { return }
        let appName = (assessment.bundlePath as NSString).lastPathComponent
        guard let sourceDiskImage = mountedDiskImageSourceForAppBundle(appName: appName) else { return }
        promptToTrashSourceDiskImageIfNeeded(sourceDiskImage)
    }

    private static func terminateSiblingApplicationsBeforeMoveIfNeeded() -> Bool {
        let applications = siblingRunningApplications()
        guard !applications.isEmpty else { return true }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "실행 중인 ClaudeUsage를 종료할까요?"
        alert.informativeText = "이미 실행 중인 앱을 닫은 뒤 Applications 폴더로 이동해야 중복 실행과 업데이트 문제가 생기지 않습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "종료하고 이동")
        alert.addButton(withTitle: "취소")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let targetProcessIDs = Set(applications.map(\.processIdentifier))
        for application in applications {
            if !application.terminate() {
                Logger.warning("기존 앱 종료 요청 실패: pid=\(application.processIdentifier)")
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stillRunning = siblingRunningApplications().filter { targetProcessIDs.contains($0.processIdentifier) }
            if stillRunning.isEmpty {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        showError("기존 ClaudeUsage를 종료하지 못해 이동을 중단했습니다.\n\n실행 중인 ClaudeUsage를 종료한 뒤 다시 시도해 주세요.")
        return false
    }

    private static func siblingRunningApplications() -> [NSRunningApplication] {
        let snapshots = NSWorkspace.shared.runningApplications.map { application in
            AppRunningApplicationSnapshot(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                isTerminated: application.isTerminated
            )
        }
        let targetProcessIDs = Set(
            AppInstallRunningApplicationPolicy.siblingApplicationsToTerminate(
                currentBundleIdentifier: Bundle.main.bundleIdentifier,
                currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                runningApplications: snapshots
            ).map(\.processIdentifier)
        )
        guard !targetProcessIDs.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { targetProcessIDs.contains($0.processIdentifier) }
    }

    private static func promptToTrashSourceDiskImageIfNeeded(_ sourceDiskImage: AppDiskImageSource?) {
        guard let sourceDiskImage else { return }

        let imageURL = URL(fileURLWithPath: sourceDiskImage.imagePath)
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "설치 DMG를 휴지통으로 이동할까요?"
        alert.informativeText = "앱은 Applications 폴더로 이동했습니다. 다운로드한 설치 파일은 더 이상 필요하지 않습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "그대로 두기")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: imageURL, resultingItemURL: &trashedURL)
            Logger.info("설치 DMG 휴지통 이동 완료")
        } catch {
            Logger.warning("설치 DMG 휴지통 이동 실패: \(error.localizedDescription)")
            showCleanupError()
        }
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

    private static func showCleanupError() {
        let alert = NSAlert()
        alert.messageText = "설치 파일 정리 실패"
        alert.informativeText = "앱은 정상적으로 이동했습니다. 설치 DMG는 Finder에서 직접 휴지통으로 이동해 주세요."
        alert.alertStyle = .warning
        alert.runModal()
    }
}
