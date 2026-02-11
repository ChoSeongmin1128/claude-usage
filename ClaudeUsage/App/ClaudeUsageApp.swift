//
//  ClaudeUsageApp.swift
//  ClaudeUsage
//
//  메뉴바 전용 앱 진입점
//

import SwiftUI

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메뉴바 전용 앱 - 창 없이 Settings만 선언
        Settings {
            EmptyView()
        }
    }
}
