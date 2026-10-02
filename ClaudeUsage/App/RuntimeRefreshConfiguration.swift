import Foundation

/// 자동 조회를 켤지. 주기는 AdaptiveRefreshPolicy가 사용 상황(팝오버, 사용 중, 한도 임박)으로 정한다.
struct RuntimeRefreshConfiguration: Equatable, Sendable {
    let autoRefresh: Bool

    init(settings: AppSettings) {
        self.init(autoRefresh: settings.autoRefresh)
    }

    init(autoRefresh: Bool) {
        self.autoRefresh = autoRefresh
    }
}
