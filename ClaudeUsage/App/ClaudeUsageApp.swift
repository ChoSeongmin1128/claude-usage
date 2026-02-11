//
//  ClaudeUsageApp.swift
//  ClaudeUsage
//
//  Phase 1: SwiftUI 앱 진입점
//

import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메뉴바 전용 앱 - WindowGroup 필요하지만 창은 숨김
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
        .defaultSize(width: 0, height: 0)
    }
}
