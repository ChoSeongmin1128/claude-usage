import SwiftUI

/// Surfaces shared by settings, provider setup and login. Layout remains owned by each component.
enum AppStatusTone {
    case info, success, warning, failure, secondary

    var color: Color {
        switch self {
        case .info: .accentColor
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemOrange)
        case .failure: Color(nsColor: .systemRed)
        case .secondary: .secondary
        }
    }
}

enum AppPanelRole {
    case low, editable, status(AppStatusTone)

    var background: Color {
        switch self {
        case .low: AppDesign.Surface.group
        case .editable: AppDesign.Surface.editable
        case .status(let tone): tone.color.opacity(0.08)
        }
    }

    var border: Color {
        switch self {
        case .low: .clear
        case .editable: AppDesign.Surface.boundary
        case .status(let tone): tone.color.opacity(0.22)
        }
    }
}

private struct AppPanelStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    var role: AppPanelRole
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(role.background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(contrast == .increased ? Color.primary : role.border, lineWidth: 1)
            }
    }
}

extension View {
    func appPanelStyle(role: AppPanelRole = .low, radius: CGFloat = AppDesign.Radius.group) -> some View {
        modifier(AppPanelStyle(role: role, radius: radius))
    }
}
