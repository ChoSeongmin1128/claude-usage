import SwiftUI
import UniformTypeIdentifiers

struct ProviderSettingsPicker: View {
    @Binding var selection: AppProviderKind

    var body: some View {
        HStack(spacing: 6) {
            ForEach(
                AppProviderKind.allCases,
                id: \.rawValue
            ) { provider in
                Button {
                    selection = provider
                } label: {
                    HStack(spacing: 7) {
                        ProviderBrandIconView(
                            provider: provider,
                            kind: .settings,
                            size: 16
                        )
                        Text(provider.displayName)
                            .font(
                                .subheadline
                                    .weight(
                                        selection
                                            == provider
                                            ? .semibold
                                            : .regular
                                    )
                            )
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    selection == provider
                        ? Color.primary
                        : Color.secondary
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous
                    )
                    .fill(
                        selection == provider
                            ? Color.accentColor
                                .opacity(0.14)
                            : Color(
                                NSColor
                                    .controlBackgroundColor
                            )
                            .opacity(0.45)
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous
                    )
                    .stroke(
                        selection == provider
                            ? Color.accentColor
                                .opacity(0.55)
                            : Color.secondary
                                .opacity(0.16),
                        lineWidth: 1
                    )
                )
                .accessibilityLabel(
                    "\(provider.displayName) 표시 설정"
                )
                .accessibilityAddTraits(
                    selection == provider
                        ? .isSelected
                        : []
                )
            }
        }
        .frame(maxWidth: 480)
        .accessibilityElement(
            children: .contain
        )
        .accessibilityLabel(
            "표시 설정 서비스 선택"
        )
    }
}

struct DisplayModePicker: View {
    @Binding var selection: PopoverDisplayEditorMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(PopoverDisplayEditorMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityLabel("팝오버 표시 방식")
    }
}

struct ProviderPopoverPreviewShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                Color(
                    NSColor.controlBackgroundColor
                )
                .opacity(0.45)
            )
            .cornerRadius(10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("팝오버 미리보기")
    }
}

struct ProviderExternalActionsView: View {
    let provider: AppProviderKind
    let compact: Bool
    let isInteractive: Bool
    let onOpen: (ProviderExternalAction) -> Void

    init(
        provider: AppProviderKind,
        compact: Bool,
        isInteractive: Bool = true,
        onOpen: @escaping (ProviderExternalAction) -> Void
    ) {
        self.provider = provider
        self.compact = compact
        self.isInteractive = isInteractive
        self.onOpen = onOpen
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            ForEach(provider.descriptor.externalActions) { action in
                if isInteractive {
                    Button {
                        onOpen(action)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.borderless)
                    .help(action.helpText)
                    .accessibilityLabel("\(provider.displayName) \(action.title) 열기")
                } else {
                    actionLabel(action)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .font(.caption)
    }

    private func actionLabel(
        _ action: ProviderExternalAction
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: action.systemImageName)
            if !compact {
                Text(action.title)
            }
        }
        .foregroundStyle(Color.accentColor)
    }
}

struct ProviderDisplayEditorShell<
    Preview: View,
    Controls: View
>: View {
    let title: String
    let description: String
    @Binding var selectedMode: PopoverDisplayEditorMode
    private let preview: Preview
    private let controls: Controls

    init(
        title: String,
        description: String,
        selectedMode: Binding<PopoverDisplayEditorMode>,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        self.description = description
        _selectedMode = selectedMode
        self.preview = preview()
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            DisplayModePicker(selection: $selectedMode)

            ProviderPopoverPreviewShell {
                preview
            }

            controls
        }
    }
}

struct DisplayItemRow: View {
    let item: ProviderDisplayEditorItem
    var showsDragHandle = true
    let onToggleVisibility: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }

            Button(action: onToggleVisibility) {
                Image(
                    systemName:
                        item.isVisible
                            ? "eye"
                            : "eye.slash"
                )
                .foregroundStyle(
                    item.isVisible
                        ? .primary
                        : .tertiary
                )
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(item.isVisible ? "숨기기" : "보이기")
            .accessibilityLabel(
                "\(item.title) \(item.isVisible ? "숨기기" : "보이기")"
            )

            Text(item.title)
                .font(.subheadline)
                .foregroundStyle(
                    item.isVisible
                        ? .primary
                        : .tertiary
                )

            if !item.isAvailable {
                Text("지금 데이터 없음")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(
                        "현재 응답에는 이 항목의 데이터가 없습니다. 선택은 유지됩니다."
                    )
            }

            Spacer()
        }
        .frame(height: 26)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityValue(
            [
                item.isVisible ? "표시 중" : "숨김",
                item.isAvailable
                    ? nil
                    : "지금 데이터 없음",
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        .accessibilityAction(
            named: "위로 이동",
            onMoveUp
        )
        .accessibilityAction(
            named: "아래로 이동",
            onMoveDown
        )
    }
}

struct DisplayItemList: View {
    let model: ProviderDisplayEditorModel
    let onToggleVisibility: (String) -> Void
    let onMoveByOffset: (String, Int) -> Void
    let onMoveToItem: (String, String) -> Void

    @State private var draggingItemID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(
                Array(model.items.enumerated()),
                id: \.element.id
            ) { index, item in
                if model.showsGroupHeadings,
                   shouldShowGroupHeading(
                    at: index
                   )
                {
                    if index > 0 {
                        Divider()
                    }
                    Text(item.groupTitle ?? "기타")
                        .font(
                            .caption.weight(
                                .semibold
                            )
                        )
                        .foregroundStyle(.secondary)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }

                DisplayItemRow(
                    item: item,
                    showsDragHandle:
                        model.supportsReordering,
                    onToggleVisibility: {
                        onToggleVisibility(item.id)
                    },
                    onMoveUp: {
                        onMoveByOffset(item.id, -1)
                    },
                    onMoveDown: {
                        onMoveByOffset(item.id, 1)
                    }
                )
                .background(
                    draggingItemID == item.id
                        ? Color.accentColor
                            .opacity(0.1)
                        : Color.clear
                )
                .cornerRadius(4)
                .modifier(
                    DisplayItemDragModifier(
                        enabled:
                            model
                                .supportsReordering,
                        itemID: item.id,
                        draggingItemID:
                            $draggingItemID,
                        onMoveToItem:
                            onMoveToItem
                    )
                )

                if index < model.items.count - 1,
                   !model.showsGroupHeadings
                {
                    Divider()
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            Color(
                NSColor.windowBackgroundColor
            )
            .opacity(0.6)
        )
        .cornerRadius(6)
    }

    private func shouldShowGroupHeading(
        at index: Int
    ) -> Bool {
        guard index > 0 else {
            return true
        }
        return model.items[index - 1].groupTitle
            != model.items[index].groupTitle
    }
}

private struct DisplayItemDragModifier:
    ViewModifier
{
    let enabled: Bool
    let itemID: String
    @Binding var draggingItemID: String?
    let onMoveToItem: (String, String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggingItemID = itemID
                    return NSItemProvider(
                        object: itemID as NSString
                    )
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: DisplayItemDropDelegate(
                        targetID: itemID,
                        draggingItemID:
                            $draggingItemID,
                        onMoveToItem:
                            onMoveToItem
                    )
                )
        } else {
            content
        }
    }
}

private struct DisplayItemDropDelegate:
    DropDelegate
{
    let targetID: String
    @Binding var draggingItemID: String?
    let onMoveToItem: (String, String) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceID = draggingItemID
        else {
            return false
        }
        if sourceID != targetID {
            onMoveToItem(sourceID, targetID)
        }
        draggingItemID = nil
        return true
    }

    func dropUpdated(
        info: DropInfo
    ) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
