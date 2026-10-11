import Foundation

/// 일시 실패 한 번으로는 마지막 값을 이전 값으로 표시하지 않는다. 로그인 만료는 값을 지우므로 바로 드러난다.
nonisolated enum StaleDataPolicy {
    static let consecutiveFailures = 2

    static func showsPreviousValue(afterConsecutiveFailures count: Int) -> Bool {
        count >= consecutiveFailures
    }
}
