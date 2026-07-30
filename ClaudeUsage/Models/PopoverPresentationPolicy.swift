import AppKit

struct PopoverPresentationPolicy {
    let layoutSpec: PopoverLayoutSpec
    let isShown: Bool
    let measuredContentSize: CGSize?
    let screenVisibleFrame: CGRect?

    func targetSize() -> CGSize {
        // PopoverLayoutSpec가 콘텐츠 구조에서 높이를 결정한다. 이미 고정 프레임이
        // 적용된 NSHostingView의 fittingSize로 다시 줄이면 provider 전환 시 이전
        // 프레임을 재사용해 여백이나 잘림이 생길 수 있다.
        layoutSpec.size
    }
}
