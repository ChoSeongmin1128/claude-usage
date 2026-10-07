import SwiftUI

nonisolated enum ResetCreditVisibility {
    static let coordinateSpace = "reset-credit-popover"

    struct Row: Equatable, Sendable {
        let compact: Bool
        let frame: CGRect
        let receipt: ResetCreditSeenReceipt
    }

    struct Value: Equatable, Sendable {
        var viewports: [Bool: CGRect] = [:]
        var rows: [Row] = []

        var visibleReceipts: Set<ResetCreditSeenReceipt> {
            Set(
                rows.compactMap { row in
                    guard row.frame.width > 0, row.frame.height > 0,
                        viewports[row.compact]?.contains(row.frame) == true
                    else { return nil }
                    return row.receipt
                })
        }
    }
}

nonisolated struct ResetCreditVisibilityKey: PreferenceKey {
    static let defaultValue = ResetCreditVisibility.Value()

    static func reduce(value: inout ResetCreditVisibility.Value, nextValue: () -> ResetCreditVisibility.Value) {
        let next = nextValue()
        value.viewports.merge(next.viewports) { _, latest in latest }
        value.rows += next.rows
    }
}

struct ResetCreditViewport: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ResetCreditVisibilityKey.self,
                    value: ResetCreditVisibility.Value(
                        viewports: [compact: proxy.frame(in: .named(ResetCreditVisibility.coordinateSpace))]))
            }
        }
    }
}

struct ResetCreditRowVisibility: ViewModifier {
    let compact: Bool
    let receipt: ResetCreditSeenReceipt?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ResetCreditVisibilityKey.self,
                    value: ResetCreditVisibility.Value(
                        rows: receipt.map {
                            [
                                ResetCreditVisibility.Row(
                                    compact: compact,
                                    frame: proxy.frame(in: .named(ResetCreditVisibility.coordinateSpace)),
                                    receipt: $0)
                            ]
                        } ?? []))
            }
        }
    }
}
