import SwiftUI

/// A user-driven, two-state illustration. No replay tasks, timers, live data or
/// preference mutations; both columns use the same policy as the application.
struct AppMotionComparisonView: View {
    let category: AppMotionCategory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var changed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack(spacing: AppDesign.Space.content) {
                example(mode: .instant)
                example(mode: .smooth)
            }
            HStack {
                Text(
                    category == .popoverPresentation
                        ? "동작 예시 · 실제 창 효과는 macOS에 따라 다릅니다."
                        : "동작 예시 · 아래 버튼으로 변화를 비교합니다."
                )
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("비교 재생", systemImage: "play.fill") { changed.toggle() }
                    .controlSize(.small)
            }
        }
        .padding(AppDesign.Space.content)
        .background(AppDesign.Surface.subtleGroup, in: RoundedRectangle(cornerRadius: AppDesign.Radius.group))
    }

    private func example(mode: AppMotionMode) -> some View {
        VStack(spacing: AppDesign.Space.control) {
            Text(mode.title).font(AppDesign.Typography.caption.weight(.semibold))
            scene
                .animation(
                    AppMotionPreferences(mode: mode).animation(for: category, reduceMotion: reduceMotion),
                    value: changed
                )
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .clipped()
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var scene: some View {
        switch category {
        case .popoverPresentation:
            panel("사용량", width: 120, height: 48)
                .opacity(changed ? 0 : 1).scaleEffect(changed ? 0.95 : 1)
        case .popoverResize:
            panel(changed ? "일반 보기" : "간소화", width: changed ? 180 : 110, height: changed ? 64 : 32)
        case .navigation:
            ZStack {
                panel(changed ? "표시 설정" : "일반 설정", width: 150, height: 56)
                    .id(changed).transition(.opacity)
            }
        case .disclosure:
            VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
                HStack {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(changed ? 90 : 0))
                    Text("고급 진단")
                }
                if changed {
                    Text("조회 상태 · 연결 정보").foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .font(AppDesign.Typography.caption)
        case .itemChanges:
            HStack(spacing: AppDesign.Space.row) {
                ForEach(changed ? [2, 1] : [1, 2], id: \.self) { value in
                    Text("항목 \(value)").font(AppDesign.Typography.caption)
                        .padding(AppDesign.Space.row)
                        .background(
                            value == 1 ? Color.accentColor.opacity(0.2) : AppDesign.Surface.track,
                            in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
                }
            }
        case .usageValue:
            VStack(spacing: AppDesign.Space.row) {
                Text(changed ? "65%" : "25%").font(AppDesign.Typography.caption).monospacedDigit()
                ZStack(alignment: .leading) {
                    Capsule().fill(AppDesign.Surface.track)
                    Capsule().fill(Color.accentColor).frame(width: changed ? 104 : 40)
                }
                .frame(width: 160, height: 8)
            }
        }
    }

    private func panel(_ title: String, width: CGFloat, height: CGFloat) -> some View {
        Text(title).font(AppDesign.Typography.caption)
            .frame(width: width, height: height)
            .background(AppDesign.Surface.selection, in: RoundedRectangle(cornerRadius: AppDesign.Radius.group))
    }
}
