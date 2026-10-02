import SwiftUI

struct WhatsNewView: View {
    let pages: [WhatsNewPage]
    let onAction: (WhatsNewPage.Action) -> Void
    let onClose: () -> Void
    @State private var index = 0

    var body: some View {
        let page = pages[min(index, pages.count - 1)]
        VStack(spacing: AppDesign.Space.content) {
            Text(page.version)
                .font(AppDesign.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: page.symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(AppDesign.Surface.group, in: RoundedRectangle(cornerRadius: AppDesign.Radius.panel))
                .accessibilityHidden(true)
            Text(page.title).font(AppDesign.Typography.headline)
            Text(page.body)
                .font(AppDesign.Typography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action = page.action, let title = page.actionTitle {
                Button(title) { onAction(action) }.buttonStyle(.link)
            }
            Spacer(minLength: 0)
            HStack {
                HStack(spacing: AppDesign.Space.control) {
                    ForEach(pages.indices, id: \.self) { dot in
                        Circle()
                            .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("\(pages.count)장 중 \(index + 1)장")
                Spacer()
                if index < pages.count - 1 {
                    Button("나중에", action: onClose)
                    Button("다음") { index += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("완료", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(AppDesign.Space.window)
        .frame(width: 340, height: 360)
    }
}
