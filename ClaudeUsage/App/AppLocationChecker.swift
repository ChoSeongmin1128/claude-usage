import AppKit

@MainActor
enum AppLocationChecker {
    static func checkAndGuideIfNeeded() {
        let assessment = AppInstallLocationPolicy.currentAssessment()
        Logger.info("앱 실행 위치: \(assessment.bundlePath) (\(assessment.kind.rawValue))")
        guard AppInstallGuidancePolicy.shouldShow(assessment: assessment) else { return }

        let alert = NSAlert()
        alert.messageText = "Applications 폴더에서 실행해 주세요"
        alert.informativeText =
            "현재 \(assessment.locationDescription)에서 실행 중입니다. Finder에서 앱 아이콘을 Applications 폴더로 드래그한 뒤 그곳에서 다시 실행하세요. 현재 앱은 계속 사용할 수 있지만, 이 위치에서는 자동 업데이트와 재실행이 불안정할 수 있습니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
