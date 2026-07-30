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
            DeferredSettingsRootView(
                appDelegate: appDelegate
            )
        }
    }
}

private struct DeferredSettingsRootView: View {
    let appDelegate: AppDelegate
    @State private var antigravityRuntimeController:
        AntigravityRuntimeController?

    var body: some View {
        Group {
            if let antigravityRuntimeController {
                appDelegate.makeSettingsView(
                    antigravityRuntimeController:
                        antigravityRuntimeController
                )
            } else {
                ProgressView("설정 준비 중")
                    .frame(
                        minWidth: 800,
                        minHeight: 560
                    )
            }
        }
        .task {
            guard antigravityRuntimeController
                    == nil
            else {
                return
            }
            let runtime =
                await appDelegate
                    .antigravityRuntimeTask
                    .value
            guard !Task.isCancelled else {
                return
            }
            antigravityRuntimeController =
                runtime.runtimeController
        }
    }
}
