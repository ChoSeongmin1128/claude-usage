import SwiftUI

struct AppSettingRow<Control: View>: View {
    let title: String
    let detail: String?
    private let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: AppDesign.Space.row) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title).font(AppDesign.Typography.body)
                if let detail {
                    Text(detail).font(AppDesign.Typography.caption).foregroundStyle(AppDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control.font(AppDesign.Typography.body).controlSize(.regular)
        }
        .frame(
            minHeight: detail == nil ? AppDesign.Control.settingsRowHeight : AppDesign.Control.settingsDetailRowHeight
        )
        .accessibilityElement(children: .contain)
    }
}
