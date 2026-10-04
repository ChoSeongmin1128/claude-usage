import SwiftUI

/// 설정의 서비스 상태 배지
struct RuntimeProviderBadgeView: View {
    enum Tone: Sendable, Equatable {
        case secondary, blue, orange, red
    }

    let title: String
    let tone: Tone

    var body: some View {
        Text(title)
            .font(AppDesign.Typography.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .cornerRadius(AppDesign.Radius.control)
    }

    private var color: Color {
        switch tone {
        case .secondary: return .secondary
        case .blue: return .blue
        case .orange: return .orange
        case .red: return .red
        }
    }
}
