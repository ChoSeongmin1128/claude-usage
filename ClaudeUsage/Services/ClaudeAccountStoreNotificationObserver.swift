//
//  ClaudeAccountStoreNotificationObserver.swift
//  ClaudeUsage
//
//  ClaudeAccountStore 변경 알림(.claudeAccountsDidChange)을 actor 와 분리된
//  Sendable wrapper 로 받아준다. actor 가 직접 NSNotificationCenter observer
//  token 의 수명을 관리하면 isolation/deinit 처리가 까다로워지므로, 이 클래스가
//  대신 token 을 보유하고 deinit 시점에 해제한다.
//

import Foundation

nonisolated final class ClaudeAccountStoreNotificationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init() {}

    /// `.claudeAccountsDidChange` 알림이 도착할 때마다 `handler` 를 호출한다.
    /// 호출되는 스레드는 NotificationCenter 기본 동작(발행 스레드와 동일)이며,
    /// 호출자는 필요시 자체적으로 actor / main 큐로 디스패치해야 한다.
    /// 두 번 호출하면 기존 구독을 해제하고 새 핸들러로 교체한다.
    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if let existing = token {
            NotificationCenter.default.removeObserver(existing)
        }
        token = NotificationCenter.default.addObserver(
            forName: .claudeAccountsDidChange,
            object: nil,
            queue: nil
        ) { _ in
            handler()
        }
        lock.unlock()
    }

    /// 명시적으로 구독을 해제한다. deinit 에서도 자동 호출되지만, 테스트에서
    /// 결정적인 시점에 정리하고 싶을 때 사용한다.
    func stop() {
        lock.lock()
        if let existing = token {
            NotificationCenter.default.removeObserver(existing)
            token = nil
        }
        lock.unlock()
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
