import SwiftUI
import UniformTypeIdentifiers

struct DisplayModePicker: View {
    @Binding var selection: PopoverDisplayEditorMode

    var body: some View {
        Picker("편집할 목록", selection: $selection) {
            ForEach(PopoverDisplayEditorMode.allCases) { mode in
                Text(mode.title)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityLabel("편집할 목록")
    }
}

struct ProviderPopoverPreviewShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppDesign.Space.content)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                Color(
                    NSColor.controlBackgroundColor
                )
                .opacity(0.45)
            )
            .cornerRadius(AppDesign.Radius.card)
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
                IconActionButton(
                    symbol: action.systemImageName,
                    label: "\(provider.displayName) \(action.title) 웹사이트 열기",
                    compact: compact, isExternal: true
                ) { if isInteractive { onOpen(action) } }
                .allowsHitTesting(isInteractive)
                .accessibilityHidden(!isInteractive)
            }
        }
        .font(AppDesign.Typography.caption)
    }
}

struct ProviderDisplayEditorShell<
    Preview: View,
    Controls: View
>: View {
    let title: String
    @Binding var selectedMode: PopoverDisplayEditorMode
    private let preview: Preview
    private let controls: Controls

    init(
        title: String,
        selectedMode: Binding<PopoverDisplayEditorMode>,
        @ViewBuilder preview: () -> Preview,
        @ViewBuilder controls: () -> Controls
    ) {
        self.title = title
        _selectedMode = selectedMode
        self.preview = preview()
        self.controls = controls()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text(title)
                .font(AppDesign.Typography.subheadline.weight(.semibold))

            DisplayModePicker(selection: $selectedMode)

            ProviderPopoverPreviewShell {
                preview
            }

            controls
                .accessibilityElement(children: .contain)
                .accessibilityLabel("팝오버 편집 목록")
                .accessibilityIdentifier("popover-display-items")
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
        HStack(spacing: AppDesign.Space.row) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(AppDesign.Typography.metadata)
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
                .font(AppDesign.Typography.icon)
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(item.isVisible ? "숨기기" : "보이기")
            .accessibilityLabel(
                "\(item.title) \(item.isVisible ? "숨기기" : "보이기")"
            )

            Text(item.title)
                .font(AppDesign.Typography.subheadline)
                .foregroundStyle(
                    item.isVisible
                        ? .primary
                        : .tertiary
                )

            if !item.isAvailable {
                Text("데이터 없음")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(height: 26)
        .padding(.horizontal, AppDesign.Space.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityValue(
            [
                item.isVisible ? "표시 중" : "숨김",
                item.isAvailable
                    ? nil
                    : "데이터 없음",
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
                        .padding(.horizontal, AppDesign.Space.row)
                        .padding(.top, AppDesign.Space.control)
                        .padding(.bottom, AppDesign.Space.tight)
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
                        itemIDs: Set(model.items.map(\.id)),
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
                        .padding(.horizontal, AppDesign.Space.row)
                }
            }
        }
        .padding(.vertical, AppDesign.Space.compact)
        .background(
            Color(
                NSColor.windowBackgroundColor
            )
            .opacity(0.6)
        )
        .cornerRadius(AppDesign.Radius.control)
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
    let itemIDs: Set<String>
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
                        itemIDs: itemIDs,
                        draggingItemID:
                            $draggingItemID,
                        onMoveToItem:
                            onMoveToItem
                    )
                )
                // 드래그를 목록 밖에서 놓거나 취소하면 끝났다는 신호가 없다. 드래그가 끝나야 마우스 위치가
                // 다시 전달되므로 그때 강조를 지운다.
                .onContinuousHover { phase in
                    if case .active = phase, draggingItemID != nil { draggingItemID = nil }
                }
        } else {
            content
        }
    }
}

private struct DisplayItemDropDelegate:
    DropDelegate
{
    let targetID: String
    let itemIDs: Set<String>
    @Binding var draggingItemID: String?
    let onMoveToItem: (String, String) -> Void

    /// 끌어 온 항목 id는 남아 있는 상태가 아니라 놓은 자료에서 읽는다. 취소된 드래그의 id가 남아 있어도
    /// 다른 앱의 글자를 놓았을 때 항목이 움직이지 않게 한다.
    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        Task { @MainActor in
            guard let sourceID = await Self.droppedID(from: provider), itemIDs.contains(sourceID),
                sourceID != targetID
            else { return }
            onMoveToItem(sourceID, targetID)
        }
        return true
    }

    private static func droppedID(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }

    func dropUpdated(
        info: DropInfo
    ) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
