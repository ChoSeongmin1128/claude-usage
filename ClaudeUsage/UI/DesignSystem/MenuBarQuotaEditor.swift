import AppKit
import SwiftUI

private nonisolated struct MenuBarQuotaRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, current in current }
    }
}

struct MenuBarQuotaEditor: View {
    let model: MenuBarQuotaEditorModel
    var previewsEditedArrangement = false
    let renderPreview: (MenuBarQuotaArrangement, String?) -> MenuBarQuotaPreviewLayout
    let onAction: (MenuBarQuotaEditorAction) -> Void
    @State private var expandedID: String?
    @State private var highlightedID: String?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var rowDrag: RowDrag?
    @State private var rowDragCancelled = false
    @GestureState private var isRowGestureActive = false
    @FocusState private var focusedID: String?
    @Namespace private var coordinateSpace

    private struct RowDrag {
        let id: String
        let originalFrame: CGRect
        let originalIDs: [String]
        let targetFrames: [String: CGRect]
        var ids: [String]
        var translation: CGSize
    }

    private var displayedModel: MenuBarQuotaEditorModel {
        rowDrag.map { model.reordering($0.ids) } ?? model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            preview
            HStack {
                Text("메뉴바에 표시할 한도").font(AppDesign.Typography.subheadline.weight(.semibold))
                Spacer()
                Text("손잡이를 위아래로 끌어 정렬")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(displayedModel.selectedItems) { item in
                    quotaRow(item)
                    if item.id != displayedModel.selectedItems.last?.id { Divider() }
                }
                if displayedModel.selectedItems.isEmpty {
                    Text("메뉴바에서 볼 한도를 추가하세요.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                        .padding(AppDesign.Space.content)
                }
            }
            .background(
                AppDesign.Surface.subtleGroup,
                in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
            addMenu
        }
        .coordinateSpace(name: coordinateSpace)
        .overlay(alignment: .topLeading) {
            if let drag = rowDrag, let item = model.items.first(where: { $0.id == drag.id }) {
                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: "line.3.horizontal")
                    Text(item.title).font(AppDesign.Typography.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(AppDesign.Space.row)
                .frame(width: drag.originalFrame.width)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
                .position(
                    x: drag.originalFrame.midX,
                    y: drag.originalFrame.midY + drag.translation.height
                )
                .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(MenuBarQuotaRowFrames.self) { rowFrames = $0 }
        .onChange(of: model.provider) { _, _ in cancelRowDrag() }
        .onChange(of: model.selectedItems.map(\.id)) { _, _ in cancelRowDrag() }
        .onChange(of: model.arrangement) { _, _ in cancelRowDrag() }
        .onExitCommand { cancelRowDrag() }
        .onDisappear { cancelRowDrag() }
        .onChange(of: isRowGestureActive) { _, active in
            if !active {
                rowDrag = nil
                rowDragCancelled = false
            }
        }
    }

    private var preview: some View {
        let layout = renderPreview(displayedModel.arrangement, highlightedID ?? focusedID)
        return VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
            Text(previewsEditedArrangement ? "배치 미리보기" : "메뉴바 미리보기").font(AppDesign.Typography.caption).foregroundStyle(
                .secondary)
            ScrollView(.horizontal) {
                MenuBarQuotaPreview(
                    layout: layout,
                    onSelect: { ids in
                        if let id = ids.first {
                            expandedID = expandedID == id ? nil : id
                            highlightedID = id
                        }
                    },
                    onReorder: { ids in onAction(.reorderUnits(ids)) },
                    onHover: { highlightedID = $0 }
                )
                .frame(width: max(1, layout.width), height: 30)
            }
            .scrollIndicators(.hidden)
            let activeID = highlightedID ?? focusedID
            let activeItem = displayedModel.selectedItems.first { $0.id == activeID }
            Text(
                activeItem.map { item in
                    [item.title, displayedModel.role(for: item.id)?.title].compactMap { $0 }.joined(separator: " / ")
                } ?? " "
            )
            .font(AppDesign.Typography.caption).foregroundStyle(Color.accentColor).lineLimit(1)
            .accessibilityHidden(activeItem == nil)
            Text(
                previewsEditedArrangement
                    ? "목록에서 표시 방식이나 순서를 바꾸면 이 배치가 적용됩니다."
                    : "미리보기에서 끌어 순서를 바꾸고, 눌러 표시 방식을 바꿉니다."
            )
            .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
        .padding(AppDesign.Space.row)
        .background(
            AppDesign.Surface.subtleGroup,
            in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
    }

    private func quotaRow(_ item: MenuBarQuotaEditorItem) -> some View {
        let role = displayedModel.role(for: item.id)
        return VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack(spacing: AppDesign.Space.row) {
                Button {
                    focusedID = item.id
                } label: {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        .frame(width: 22, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused($focusedID, equals: item.id)
                .help("끌어서 순서 변경")
                .accessibilityLabel("\(item.title) 순서 변경")
                .accessibilityHint("위아래 방향키로도 순서를 바꿀 수 있습니다")
                .onMoveCommand { direction in
                    if direction == .up { move(item.id, by: -1) }
                    if direction == .down { move(item.id, by: 1) }
                }
                .highPriorityGesture(rowGesture(item.id))
                if let role { MenuBarQuotaRoleGlyph(role: role, isCircular: model.shape.gaugeShape == .circular) }
                Button {
                    expandedID = expandedID == item.id ? nil : item.id
                } label: {
                    VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                        Text(item.title).font(AppDesign.Typography.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(
                            item.usedPercentage == nil && !item.canSelect
                                ? "데이터 없음" : displayedModel.summary(for: item.id)
                        )
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help(item.title)
                Button(expandedID == item.id ? "접기" : "편집") {
                    expandedID = expandedID == item.id ? nil : item.id
                }.buttonStyle(.borderless).font(AppDesign.Typography.caption)
                Button {
                    onAction(.remove(item.id))
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless).accessibilityLabel("\(item.title) 메뉴바에서 제거")
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MenuBarQuotaRowFrames.self,
                        value: [item.id: proxy.frame(in: .named(coordinateSpace))])
                })
            if expandedID == item.id {
                HStack(spacing: AppDesign.Space.row) {
                    surfaceButton("게이지", id: item.id, surface: .gauge)
                    surfaceButton("숫자", id: item.id, surface: .percentage, symbol: "number")
                    surfaceButton("초기화 시간", id: item.id, surface: .reset, symbol: "clock")
                }
            }
        }
        .padding(AppDesign.Space.row)
        .background(role == nil || role == .single ? Color.clear : Color.accentColor.opacity(0.05))
        .opacity(rowDrag?.id == item.id ? 0.2 : 1)
        .onHover { hovering in highlightedID = hovering ? item.id : nil }
        .accessibilityAction(named: Text("앞으로 이동")) { move(item.id, by: -1) }
        .accessibilityAction(named: Text("뒤로 이동")) { move(item.id, by: 1) }
    }

    private func surfaceButton(
        _ title: String, id: String, surface: MenuBarQuotaSelection.Surface, symbol: String? = nil
    ) -> some View {
        let selected = model.selection.ids(for: surface).contains(id)
        let item = model.items.first { $0.id == id }
        return Button {
            onAction(.setSurface(id, surface, !selected))
        } label: {
            HStack(spacing: AppDesign.Space.tight) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(AppDesign.Typography.caption)
            .padding(.horizontal, AppDesign.Space.row).padding(.vertical, 7)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!selected && (item?.canSelect != true || item?.selectableSurfaces.contains(surface) != true))
        .accessibilityLabel("\(item?.title ?? "한도") \(title)")
        .accessibilityValue(selected ? "켬" : "끔")
    }

    private var addMenu: some View {
        Menu {
            ForEach(model.availableItems) { item in Button(item.title) { onAction(.add(item.id)) } }
        } label: {
            Label("한도 추가", systemImage: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(model.availableItems.isEmpty)
    }

    private func rowGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpace))
            .updating($isRowGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !rowDragCancelled else { return }
                if rowDrag == nil, let rect = rowFrames[id] {
                    let ids = model.selectedItems.map(\.id)
                    rowDrag = RowDrag(
                        id: id, originalFrame: rect, originalIDs: ids,
                        targetFrames: rowFrames, ids: ids, translation: .zero)
                }
                guard var drag = rowDrag, drag.id == id else { return }
                drag.translation = CGSize(width: 0, height: value.translation.height)
                var ids = drag.originalIDs.filter { $0 != id }
                let center = drag.originalFrame.midY + value.translation.height
                let next = ids.firstIndex { drag.targetFrames[$0].map { center < $0.midY } ?? false } ?? ids.count
                ids.insert(id, at: next)
                drag.ids = ids
                rowDrag = drag
                highlightedID = id
            }
            .onEnded { _ in
                let endedDrag = rowDrag
                rowDrag = nil
                rowDragCancelled = false
                guard let drag = endedDrag else { return }
                guard drag.originalIDs == model.selectedItems.map(\.id) else { return }
                if drag.ids != drag.originalIDs { onAction(.reorderQuotas(drag.ids)) }
                focusedID = drag.id
            }
    }

    private func cancelRowDrag() {
        guard rowDrag != nil else { return }
        rowDrag = nil
        rowDragCancelled = true
    }

    private func move(_ id: String, by offset: Int) {
        var ids = model.selectedItems.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        onAction(.reorderQuotas(ids))
    }
}

private struct MenuBarQuotaRoleGlyph: View {
    let role: MenuBarQuotaRole
    let isCircular: Bool

    var body: some View {
        VStack(spacing: 2) {
            if isCircular {
                ZStack {
                    Circle().stroke(role == .inner ? Color.secondary : Color.accentColor, lineWidth: 2)
                    if role != .single {
                        Circle().stroke(role == .inner ? Color.accentColor : Color.secondary, lineWidth: 2)
                            .frame(width: 12, height: 12)
                    }
                }.frame(width: 26, height: 26)
            } else {
                VStack(spacing: 3) {
                    Capsule().fill(role == .bottom ? Color.secondary : Color.accentColor).frame(height: 7)
                    if role != .single {
                        Capsule().fill(role == .bottom ? Color.accentColor : Color.secondary).frame(height: 7)
                    }
                }.frame(width: 26, height: 26)
            }
            Text(role.title).font(AppDesign.Typography.caption).foregroundStyle(Color.accentColor)
        }.frame(width: 46).accessibilityLabel(role.title)
    }
}
