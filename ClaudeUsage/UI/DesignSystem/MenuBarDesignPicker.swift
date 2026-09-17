import AppKit
import SwiftUI

struct MenuBarDesignPicker: View {
    @ObservedObject var settings: AppSettings
    var style: MenuBarStyle = .batteryBar
    var basis: UsageValueBasis = .remaining

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Text("메뉴바 디자인").font(AppDesign.Typography.headline)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(style == .none ? "배터리 예시입니다. 실제 표시 항목은 바뀌지 않습니다." : "선택한 스타일의 디자인 예시입니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
    }

    private func choice(_ design: MenuBarDesign) -> some View {
        Button {
            settings.menuBarDesign = design
        } label: {
            HStack(spacing: AppDesign.Space.row) {
                Image(systemName: settings.menuBarDesign == design ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.menuBarDesign == design ? Color.accentColor : .secondary)
                Text(design.title).font(AppDesign.Typography.subheadline)
                MenuBarDesignPreview(design: design, colorMode: settings.menuBarColorMode, style: style, basis: basis)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding(AppDesign.Space.row)
            .frame(minHeight: AppDesign.Control.disclosureRowHeight)
            .background(
                settings.menuBarDesign == design ? AppDesign.Surface.selection : AppDesign.Surface.group,
                in: RoundedRectangle(cornerRadius: AppDesign.Radius.control)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(design.title) 메뉴바 디자인")
        .accessibilityValue(settings.menuBarDesign == design ? "선택됨" : "선택 안 됨")
    }

}

struct MenuBarDesignPreview: View {
    let design: MenuBarDesign
    let colorMode: MenuBarColorMode
    var style: MenuBarStyle = .batteryBar
    var basis: UsageValueBasis = .remaining
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: previewImage)
            .accessibilityLabel("디자인 예시")
            .accessibilityValue(basis.spokenValue(fromUsed: 20))
    }

    private var previewImage: NSImage {
        let monochrome = colorMode != .always
        let color: NSColor = monochrome ? .labelColor : .systemGreen
        var image = NSImage()
        let primary = basis.percentage(fromUsed: 20)
        let secondary = basis.percentage(fromUsed: 45)
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            switch style {
            case .none, .batteryBar:
                image = MenuBarIconRenderer.batteryIcon(
                    percentage: primary, color: color, design: design, monochrome: monochrome)
            case .circular:
                image = MenuBarIconRenderer.circularRingIcon(percentage: primary, color: color, design: design)
            case .concentricRings:
                image = MenuBarIconRenderer.concentricRingsIcon(
                    outerPercent: primary, innerPercent: secondary,
                    outerColor: color, innerColor: color, design: design)
            case .dualBattery:
                image = MenuBarIconRenderer.dualBatteryIcon(
                    topPercent: primary, bottomPercent: secondary,
                    topColor: color, bottomColor: color, design: design)
            case .sideBySideBattery:
                image = MenuBarIconRenderer.sideBySideBatteryIcon(
                    leftPercent: primary, rightPercent: secondary,
                    leftColor: color, rightColor: color, design: design, monochrome: monochrome)
            }
        }
        return image
    }
}
