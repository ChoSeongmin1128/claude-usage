import AppKit
import SwiftUI

struct MenuBarDesignPicker: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("메뉴바 디자인").font(AppDesign.Typography.headline)
            Text("예시 미리보기입니다. 디자인을 바꿔도 색상·표시 항목·사용량 기준은 유지됩니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesign.Space.row) {
                    ForEach(MenuBarDesign.allCases, id: \.rawValue) { design in
                        choice(design)
                    }
                }
                VStack(spacing: AppDesign.Space.row) {
                    ForEach(MenuBarDesign.allCases, id: \.rawValue) { design in
                        choice(design)
                    }
                }
            }
        }
    }

    private func choice(_ design: MenuBarDesign) -> some View {
        Button {
            settings.menuBarDesign = design
        } label: {
            VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                HStack {
                    Text(design.title).font(AppDesign.Typography.subheadline.weight(.semibold))
                    Spacer(minLength: AppDesign.Space.row)
                    Label("사용 중", systemImage: "checkmark.circle.fill")
                        .font(AppDesign.Typography.caption).foregroundStyle(Color.accentColor)
                        .opacity(settings.menuBarDesign == design ? 1 : 0)
                        .accessibilityHidden(settings.menuBarDesign != design)
                }
                MenuBarDesignPreview(design: design, colorMode: settings.menuBarColorMode)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(AppDesign.Space.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(settings.menuBarDesign == design ? Color.accentColor.opacity(0.08) : Color.clear)
            .appPanelStyle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(design.title) 메뉴바 디자인")
        .accessibilityValue(settings.menuBarDesign == design ? "선택됨" : "선택 안 됨")
    }

}

struct MenuBarDesignPreview: View {
    let design: MenuBarDesign
    let colorMode: MenuBarColorMode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: AppDesign.Space.row) {
            let images = previewImages
            ForEach(images.indices, id: \.self) { Image(nsImage: images[$0]) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("예시: 배터리, 원형, 동심원, 이중 배터리")
    }

    private var previewImages: [NSImage] {
        var images: [NSImage] = []
        let monochrome = colorMode != .always
        let color: NSColor = monochrome ? .labelColor : .systemGreen
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            images = [
                MenuBarIconRenderer.batteryIcon(percentage: 80, color: color, design: design, monochrome: monochrome),
                MenuBarIconRenderer.circularRingIcon(percentage: 80, color: color, design: design),
                MenuBarIconRenderer.concentricRingsIcon(
                    outerPercent: 80, innerPercent: 55, outerColor: color, innerColor: color, design: design),
                MenuBarIconRenderer.dualBatteryIcon(
                    topPercent: 80, bottomPercent: 55, topColor: color, bottomColor: color, design: design),
                MenuBarIconRenderer.sideBySideBatteryIcon(
                    leftPercent: 80, rightPercent: 55, leftColor: color, rightColor: color, design: design,
                    monochrome: monochrome),
            ]
        }
        return images
    }
}
