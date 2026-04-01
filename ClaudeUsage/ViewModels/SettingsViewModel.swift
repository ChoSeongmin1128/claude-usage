import Foundation
import Combine

@MainActor
final class SettingsViewModel: ObservableObject {
    let messagesFallbackHelpText = """
    Claude 사용량 조회가 실패할 때 Messages API의 rate limit 헤더로 최소 사용량 정보를 복구합니다.
    기본값은 꺼짐이며, 자동 보조는 사용량이 충분히 높을 때만 동작합니다.
    """

    let messagesFallbackThresholdHelpText = """
    현재 사용량이 이 값보다 낮으면 자동 보조 복구를 시도하지 않습니다.
    낮은 사용량 구간에서 불필요한 probe 호출을 줄이기 위한 안전장치입니다.
    """

    let chromeImportHelpText = """
    Chrome 로그인 상태를 우선 탐지합니다.
    가능하면 sessionKey를 자동으로 가져오고, 실패하면 sessionKey 직접 입력 안내로 이어집니다.
    """

    let weeklyDisplayHelpText = """
    퍼센트, 리셋 시간, 아이콘 스타일은 현재 세션/주간/동시 중 원하는 기준으로 선택할 수 있습니다.
    """

    func clampFallbackThreshold(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}
