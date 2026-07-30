import Foundation

/// 사용자의 포커스를 훔치는 전역 키 입력 없이 메뉴바 앱의 화면을
/// 자동화·진단할 수 있도록 명시적인 시작 의도만 해석한다.
struct ApplicationLaunchIntent: Equatable, Sendable {
    let settingsPanelRawValue: String?
    let popoverServiceRawValue: String?

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

        return Self(
            settingsPanelRawValue:
                settingsPanelRawValue,
            popoverServiceRawValue:
                popoverServiceRawValue
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
