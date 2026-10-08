import AppKit
import SwiftUI

struct MenuBarSettingsPreview: View {
    let snapshot: MenuBarProviderSnapshot?
    var unavailableText = "사용량을 확인하면 미리보기가 표시됩니다."
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: AppDesign.Space.content) {
            Text("메뉴바 미리보기").font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            if let snapshot, let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) {
                let content = MenuBarStatusComposer.singleProviderContent(
                    snapshot: snapshot, secondaryColor: .secondaryLabelColor, appearance: appearance)
                ScrollView(.horizontal) {
                    Image(nsImage: content.image)
                        .accessibilityLabel(content.accessibilityValue ?? snapshot.tooltip)
                        .help(snapshot.tooltip)
                }
                .frame(height: max(20, content.image.size.height))
            } else {
                Text(unavailableText).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                    .frame(minHeight: 20)
            }
            Spacer(minLength: 0)
        }
        .padding(AppDesign.Space.row)
        .background(AppDesign.Surface.subtleGroup, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
    }
}
