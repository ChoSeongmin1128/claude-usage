import SwiftUI

/// Surfaces shared by settings, provider setup and login. Layout remains owned by each component.
private struct AppPanelStyle: ViewModifier {
    var tone: Color?
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(tone.map { $0.opacity(0.08) } ?? AppDesign.Surface.group)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                if let tone {
                    RoundedRectangle(cornerRadius: radius).stroke(tone.opacity(0.22), lineWidth: 1)
                }
            }
    }
}

extension View {
    func appPanelStyle(tone: Color? = nil, radius: CGFloat = AppDesign.Radius.group) -> some View {
        modifier(AppPanelStyle(tone: tone, radius: radius))
    }
}
