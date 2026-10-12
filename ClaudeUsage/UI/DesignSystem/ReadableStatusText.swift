import SwiftUI

private struct ReadableStatusText: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let color: Color
    func body(content: Content) -> some View {
        content.foregroundStyle(AppDesign.Text.status(color, scheme: scheme))
    }
}

extension View {
    func appStatusTextColor(_ color: Color) -> some View { modifier(ReadableStatusText(color: color)) }
}
