import Foundation

extension Timer {
    /// 모달 경고나 메뉴를 띄운 동안에도 멈추지 않도록 주 실행 루프의 모든 공통 모드에 등록한다.
    static func scheduledOnMainRunLoop(
        interval: TimeInterval,
        repeats: Bool,
        block: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
