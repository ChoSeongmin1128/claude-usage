import AppKit
import SwiftUI

struct MenuBarSettingsPreview: View {
    let snapshot: MenuBarProviderSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: AppDesign.Space.content) {
            Text("메뉴바 미리보기").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            if let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) {
                let content = MenuBarStatusComposer.singleProviderContent(
                    snapshot: snapshot, secondaryColor: .secondaryLabelColor, appearance: appearance)
                Image(nsImage: content.image)
                    .accessibilityLabel(content.accessibilityValue ?? snapshot.tooltip)
                    .help(snapshot.tooltip)
            }
            Spacer(minLength: 0)
        }
        .padding(AppDesign.Space.row)
        .background(AppDesign.Surface.subtleGroup, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
    }
}
