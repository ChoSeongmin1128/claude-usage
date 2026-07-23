import AppKit
import SwiftUI

struct ClaudeOAuthMigrationCard: View {
    let state: ClaudeOAuthCredentialMigrationState
    let onMigrate: () -> Void
    let onDefer: () -> Void
    let onShowLoginGuidance: () -> Void

    var body: some View {
        switch state {
        case .available:
            notice(
                icon: "key.horizontal.fill",
                title: "기존 Claude 로그인 캐시 이전",
                detail: "이 Mac에 이전 버전이 만든 OAuth 캐시가 있습니다. 한 번 인증해 앱 전용 저장소로 옮기면 계정 전환 때 Keychain 암호를 다시 묻지 않습니다.",
                tone: .orange
            ) {
                Button("이전", action: onMigrate)
                    .buttonStyle(.borderedProminent)
                Button("나중에", action: onDefer)
                    .buttonStyle(.bordered)
            }
        case .migrating:
            notice(
                icon: "key.horizontal.fill",
                title: "로그인 캐시 이전 중",
                detail: "macOS 인증이 끝나면 새 저장소를 검증한 뒤 기존 캐시를 정리합니다.",
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
                title: "로그인 캐시 이전을 미뤘습니다",
                detail: "이번 실행에서는 Keychain 인증을 다시 요청하지 않습니다. 앱을 다시 실행하면 이전할 수 있습니다.",
                tone: .secondary
            ) { EmptyView() }
        case .completed:
            notice(
                icon: "checkmark.shield.fill",
                title: "로그인 캐시 이전 완료",
                detail: "앞으로 ClaudeUsage가 만든 OAuth 캐시는 앱 전용 Keychain 저장소에서 관리됩니다.",
                tone: .green
            ) { EmptyView() }
        case .completedWithLegacyCleanupFailure:
            notice(
                icon: "exclamationmark.shield.fill",
                title: "새 저장소 이전 완료",
                detail: "새 저장소는 검증했지만 기존 캐시는 정리하지 못했습니다. 앱 사용에는 영향이 없으며 이전 캐시를 다시 읽지 않습니다.",
                tone: .orange
            ) { EmptyView() }
        case .failed(let message):
            notice(
                icon: "exclamationmark.triangle.fill",
                title: "로그인 캐시를 이전하지 못했습니다",
                detail: message,
                tone: .orange
            ) {
                Button("다시 시도", action: onMigrate)
                    .buttonStyle(.borderedProminent)
                Button("나중에", action: onDefer)
                    .buttonStyle(.bordered)
                Button("재로그인 안내", action: onShowLoginGuidance)
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
