import AppKit
import SwiftUI

struct ClaudeOAuthMigrationCard: View {
    let state: ClaudeOAuthCredentialMigrationState
    let onMigrate: () -> Void
    let onDefer: () -> Void
    let onReconnectClaudeCode: () -> Void

    var body: some View {
        switch state {
        case .available:
            notice(
                icon: "key.horizontal.fill",
                title: "Claude Code 연결 업데이트 필요",
                detail: "기존 Claude Code 연결을 새 보안 저장 방식으로 업데이트합니다. 처음 한 번만 macOS 인증을 완료하면 이후 앱 실행과 계정 전환에서는 암호를 다시 묻지 않습니다.",
                tone: .orange
            ) {
                Button("연결 업데이트", action: onMigrate)
                    .buttonStyle(.borderedProminent)
                Button("나중에", action: onDefer)
                    .buttonStyle(.bordered)
            }
        case .migrating:
            notice(
                icon: "key.horizontal.fill",
                title: "Claude Code 연결 업데이트 중",
                detail: "macOS 인증이 끝나면 새 보안 저장소를 확인하고 이전 연결 정보를 정리합니다.",
                tone: .orange
            ) {
                ProgressView()
                    .controlSize(.small)
                Text("처리 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .deferred:
            notice(
                icon: "clock.arrow.circlepath",
                title: "Claude Code 연결 업데이트를 미뤘습니다",
                detail: "이번 실행에서는 macOS 인증을 다시 요청하지 않습니다. 앱을 다시 실행하면 업데이트할 수 있습니다.",
                tone: .secondary
            ) { EmptyView() }
        case .completed:
            notice(
                icon: "checkmark.shield.fill",
                title: "Claude Code 연결 업데이트 완료",
                detail: "앞으로 ClaudeUsage의 연결 정보는 앱 전용 보안 저장소에서 관리됩니다.",
                tone: .green
            ) { EmptyView() }
        case .completedWithLegacyCleanupFailure:
            notice(
                icon: "exclamationmark.shield.fill",
                title: "Claude Code 연결 업데이트 완료",
                detail: "새 보안 저장소는 확인했지만 이전 연결 정보는 정리하지 못했습니다. 앱 사용에는 영향이 없으며 이전 정보는 다시 읽지 않습니다.",
                tone: .orange
            ) { EmptyView() }
        case .failed(let message):
            notice(
                icon: "exclamationmark.triangle.fill",
                title: "Claude Code 연결을 업데이트하지 못했습니다",
                detail: message,
                tone: .orange
            ) {
                Button("다시 시도", action: onMigrate)
                    .buttonStyle(.borderedProminent)
                Button("나중에", action: onDefer)
                    .buttonStyle(.bordered)
                Button("현재 Claude Code로 연결", action: onReconnectClaudeCode)
                    .buttonStyle(.bordered)
            }
        case .checking, .notNeeded:
            EmptyView()
        }
    }

    private func notice<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        tone: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    actions()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tone.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tone.opacity(0.22), lineWidth: 1)
        )
        .cornerRadius(8)
        .accessibilityElement(children: .contain)
    }
}
