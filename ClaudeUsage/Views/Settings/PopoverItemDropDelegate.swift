import SwiftUI

/// provider 구분 없이 동작하는 팝오버 항목 드래그-앤-드롭 델리게이트.
/// `PopoverService`만 알면 full/compact, 어떤 provider든 같은 로직으로 재배치.
struct PopoverItemDropDelegate: DropDelegate {
    let targetID: String
    let settings: AppSettings
    let isCompact: Bool
    let service: PopoverService
    @Binding var draggingItemID: String?

    func performDrop(info: DropInfo) -> Bool {
        draggingItemID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingItemID, draggingID != targetID else { return }

        var items = isCompact
            ? settings.compactPopoverItems(for: service)
            : settings.popoverItems(for: service)
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingID }),
              let toIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            let offset = toIndex > fromIndex ? toIndex + 1 : toIndex
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: offset)
            if isCompact {
                settings.setCompactPopoverItems(items, for: service)
            } else {
                settings.setPopoverItems(items, for: service)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
