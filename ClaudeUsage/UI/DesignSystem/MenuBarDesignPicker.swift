import AppKit
import SwiftUI

struct MenuBarDesignPicker: View {
    @ObservedObject var settings: AppSettings
    var style: MenuBarStyle = .batteryBar
    var basis: UsageValueBasis = .remaining
    @State private var showsComparison = false

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
            SettingsDisclosureControl(isExpanded: $showsComparison, accessibilityLabel: "전체 스타일 비교") {
                Text("전체 스타일 비교")
            } content: {
                MenuBarDesignComparison(colorMode: settings.menuBarColorMode, basis: basis)
            }
        }
        .onAppear { consumeComparisonRequest() }
        .onChange(of: settings.designComparisonRequested) { _, requested in
            if requested { consumeComparisonRequest() }
        }
    }

    private func consumeComparisonRequest() {
        guard settings.designComparisonRequested else { return }
        showsComparison = true
        settings.designComparisonRequested = false
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
        let samplePrimaryUsed = 20.0
        let sampleSecondaryUsed = 45.0
        let primaryStatusColor = ColorProvider.nsStatusColor(for: samplePrimaryUsed)
        let secondaryStatusColor = ColorProvider.nsStatusColor(for: sampleSecondaryUsed)
        let usesMonochromeGauge = colorMode != .always
        let usesCutoutText = colorMode == .monochrome || colorMode == .warningOnly
        let primaryColor: NSColor = usesMonochromeGauge ? .labelColor : primaryStatusColor
        let secondaryColor: NSColor = usesMonochromeGauge ? .labelColor : secondaryStatusColor
        let primaryTextColor: NSColor? = colorMode == .statusNumber ? primaryStatusColor : nil
        let secondaryTextColor: NSColor? = colorMode == .statusNumber ? secondaryStatusColor : nil
        var image = NSImage()
        let primary = basis.percentage(fromUsed: samplePrimaryUsed)
        let secondary = basis.percentage(fromUsed: sampleSecondaryUsed)
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            switch style {
            case .none, .batteryBar:
                image = MenuBarIconRenderer.batteryIcon(
                    percentage: primary, color: primaryColor, design: design,
                    monochrome: usesCutoutText, textColor: primaryTextColor)
            case .circular:
                image = MenuBarIconRenderer.circularRingIcon(
                    percentage: primary, color: primaryColor, design: design)
            case .concentricRings:
                image = MenuBarIconRenderer.concentricRingsIcon(
                    outerPercent: primary, innerPercent: secondary,
                    outerColor: primaryColor, innerColor: secondaryColor, design: design)
            case .dualBattery:
                image = MenuBarIconRenderer.dualBatteryIcon(
                    topPercent: primary, bottomPercent: secondary,
                    topColor: primaryColor, bottomColor: secondaryColor, design: design)
            case .sideBySideBattery:
                image = MenuBarIconRenderer.sideBySideBatteryIcon(
                    leftPercent: primary, rightPercent: secondary,
                    leftColor: primaryColor, rightColor: secondaryColor, design: design,
                    monochrome: usesCutoutText, rightMonochrome: usesCutoutText,
                    leftTextColor: primaryTextColor, rightTextColor: secondaryTextColor)
            }
        }
        return image
    }
}

struct MenuBarDesignComparison: View {
    let colorMode: MenuBarColorMode
    let basis: UsageValueBasis

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: AppDesign.Space.section, verticalSpacing: AppDesign.Space.row) {
            GridRow {
                Text("모양").foregroundStyle(.secondary)
                Text("클래식")
                Text("새 디자인")
            }
            ForEach(MenuBarStyle.allCases.filter { $0 != .none }, id: \.rawValue) { style in
                GridRow {
                    Text(style.displayName).font(AppDesign.Typography.caption)
                    MenuBarDesignPreview(design: .classic, colorMode: colorMode, style: style, basis: basis)
                    MenuBarDesignPreview(design: .modern, colorMode: colorMode, style: style, basis: basis)
                }.frame(minHeight: AppDesign.Control.regularHitSize)
            }
        }
        .font(AppDesign.Typography.subheadline.weight(.medium))
        .padding(.vertical, AppDesign.Space.row)
        .help("같은 수치와 색상의 예시입니다. 이 비교표는 설정을 바꾸지 않습니다.")
    }
}
