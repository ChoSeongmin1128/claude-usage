import Foundation

/// 사용자의 포커스를 훔치는 전역 키 입력 없이 메뉴바 앱의 화면을
/// 자동화·진단할 수 있도록 명시적인 시작 의도만 해석한다.
struct ApplicationLaunchIntent: Equatable, Sendable {
    /// 이동 직후 재실행으로 띄운 프로세스만 단일 인스턴스 잠금을 기다린다. 일반 중복
    /// 실행은 기존대로 즉시 종료해야 하므로 의도를 인자로 구분하고, 어느 프로세스를
    /// 기다리는지까지 담아 인자가 엉뚱하게 흘러들어온 경우를 가려낸다.
    static let relaunchAfterMovePrefix = "--relaunch-after-move="

    static func relaunchAfterMoveArgument(
        predecessor: pid_t
    ) -> String {
        "\(relaunchAfterMovePrefix)\(predecessor)"
    }

    let settingsPanelRawValue: String?
    let popoverServiceRawValue: String?
    let relaunchAfterMovePredecessor: pid_t?

    static func parse(arguments: [String]) -> Self {
        let settingsPrefix = "--show-settings="
        let supportedPanels = Set([
            "common",
            "display",
            "notifications",
            "updates",
            "claude",
            "codex",
            "antigravity",
        ])
        let settingsPanelRawValue = arguments
            .first {
                $0.hasPrefix(settingsPrefix)
            }
            .map {
                String(
                    $0.dropFirst(
                        settingsPrefix.count
                    )
                )
                .lowercased()
            }
            .flatMap {
                supportedPanels.contains($0)
                    ? $0
                    : nil
            }

        let popoverPrefix = "--show-popover="
        let supportedServices = Set(
            PopoverService.allCases.map(\.rawValue)
        )
        let popoverServiceRawValue = arguments
            .first {
                $0.hasPrefix(popoverPrefix)
            }
            .map {
                String(
                    $0.dropFirst(
                        popoverPrefix.count
                    )
                )
                .lowercased()
            }
            .flatMap {
                supportedServices.contains($0)
                    ? $0
                    : nil
            }

        let relaunchAfterMovePredecessor = arguments
            .first {
                $0.hasPrefix(relaunchAfterMovePrefix)
            }
            .map {
                String(
                    $0.dropFirst(
                        relaunchAfterMovePrefix.count
                    )
                )
            }
            .flatMap { pid_t($0) }
            .flatMap { $0 > 0 ? $0 : nil }

        return Self(
            settingsPanelRawValue:
                settingsPanelRawValue,
            popoverServiceRawValue:
                popoverServiceRawValue,
            relaunchAfterMovePredecessor:
                relaunchAfterMovePredecessor
        )
    }

    var prefersSettings: Bool {
        settingsPanelRawValue != nil
    }

    var requestedPopoverService:
        PopoverService?
    {
        guard !prefersSettings,
              let popoverServiceRawValue
        else {
            return nil
        }
        return PopoverService(
            rawValue: popoverServiceRawValue
        )
    }
}
