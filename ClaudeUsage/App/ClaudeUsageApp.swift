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

    init() {
        _ = AntigravityApplicationBootstrap.prepareSettings()
    }

    var body: some Scene {
        Settings {
            appDelegate.makeSettingsView()
        }
    }
}
