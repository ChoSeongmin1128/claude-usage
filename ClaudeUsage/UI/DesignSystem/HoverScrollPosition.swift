import SwiftUI

nonisolated struct HoverScrollAnchor: Equatable {
    let id: String
    let offset: CGFloat

    static func capture(top: CGFloat, frames: [String: CGRect]) -> Self? {
        let row = frames.filter { $0.value.maxY > top }.min {
            if $0.value.minY != $1.value.minY { return $0.value.minY < $1.value.minY }
            return $0.key < $1.key
        }
        return row.map { Self(id: $0.key, offset: top - $0.value.minY) }
    }

    func restoredTop(in frames: [String: CGRect]) -> CGFloat? { frames[id].map { $0.minY + offset } }
}

private struct HoverItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func hoverPositionID(_ id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HoverItemFramesKey.self,
                    value: [id: proxy.frame(in: .named("menu-bar-hover-content"))])
            }
        }
    }

    func onHoverItemFrames(_ action: @escaping ([String: CGRect]) -> Void) -> some View {
        coordinateSpace(name: "menu-bar-hover-content")
            .onPreferenceChange(HoverItemFramesKey.self, perform: action)
    }
}
