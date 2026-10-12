import SwiftUI

struct WhatsNewView: View {
    let pages: [WhatsNewPage]
    var toggle: (WhatsNewPage.Action) -> Binding<Bool>? = { _ in nil }
    let onAction: (WhatsNewPage.Action) -> Void
    let onClose: () -> Void
    @State private var index: Int

    init(
        pages: [WhatsNewPage], toggle: @escaping (WhatsNewPage.Action) -> Binding<Bool>? = { _ in nil },
        onAction: @escaping (WhatsNewPage.Action) -> Void, onClose: @escaping () -> Void,
        initialPageIndex: Int = 0
    ) {
        self.pages = pages
        self.toggle = toggle
        self.onAction = onAction
        self.onClose = onClose
        _index = State(initialValue: min(max(0, initialPageIndex), max(0, pages.count - 1)))
    }

    var body: some View {
        let page = pages[min(index, pages.count - 1)]
        VStack(spacing: AppDesign.Space.content) {
            HStack {
                Text(page.version)
                    .font(AppDesign.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppDesign.Text.secondary)
                Spacer()
                ReleaseNotesButton()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Space.content) {
                    HStack(alignment: .top, spacing: AppDesign.Space.row) {
                        Image(systemName: page.symbol).font(AppDesign.Typography.title3)
                            .foregroundStyle(Color.accentColor).accessibilityHidden(true)
                        Text(page.title).font(AppDesign.Typography.title)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(page.body).font(AppDesign.Typography.body).foregroundStyle(AppDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = page.action, let title = page.actionTitle {
                        if let binding = toggle(action) {
                            Toggle(title, isOn: binding).toggleStyle(.switch).controlSize(.small)
                        } else {
                            Button(title) { onAction(action) }.buttonStyle(.bordered)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(page.id)
            Divider()
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
        .frame(width: AppDesign.Window.whatsNew.width, height: AppDesign.Window.whatsNew.height)
    }
}
