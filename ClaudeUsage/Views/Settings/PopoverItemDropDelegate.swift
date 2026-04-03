import SwiftUI

struct PopoverItemDropDelegate: DropDelegate {
    enum Provider {
        case claude
        case codex
    }

    let targetID: String
    let settings: AppSettings
    let isCompact: Bool
    let provider: Provider
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingItemID, draggingID != targetID else { return }

        let items: [PopoverItemConfig]
        switch (provider, isCompact) {
        case (.claude, false): items = settings.popoverItems
        case (.claude, true): items = settings.compactPopoverItems
        case (.codex, false): items = settings.codexPopoverItems
        case (.codex, true): items = settings.codexCompactPopoverItems
        }
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            let offset = toIndex > fromIndex ? toIndex + 1 : toIndex
            switch (provider, isCompact) {
            case (.claude, false):
                settings.popoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.claude, true):
                settings.compactPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.codex, false):
                settings.codexPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            case (.codex, true):
                settings.codexCompactPopoverItems.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
