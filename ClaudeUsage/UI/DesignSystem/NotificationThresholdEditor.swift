import SwiftUI

struct NotificationThresholdEditor: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.control) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesign.Space.content) { rules }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: AppDesign.Space.row) { rules }
            }
            Text(settings.notificationValueBasis == .remaining ? "이하 남았을 때 알립니다." : "이상 사용했을 때 알립니다.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
    }

    private var rules: some View {
        ForEach(settings.sortedNotificationPresets) { preset in
            let basis = settings.notificationValueBasis
            HStack(spacing: AppDesign.Space.control) {
                Toggle(
                    "알림",
                    isOn: Binding(
                        get: { settings.notificationPresets.first(where: { $0.id == preset.id })?.isEnabled ?? false },
                        set: { enabled in
                            guard let index = settings.notificationPresets.firstIndex(where: { $0.id == preset.id })
                            else { return }
                            settings.notificationPresets[index].isEnabled = enabled
                        })
                )
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(
                    "\(settings.notificationValueBasis.label) \(settings.displayedNotificationThreshold(preset))퍼센트 알림")
                TextField(
                    "퍼센트",
                    value: Binding(
                        get: { basis == .remaining ? 100 - preset.threshold : preset.threshold },
                        set: { settings.setDisplayedNotificationThreshold($0, id: preset.id, basis: basis) }
                    ), format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder).frame(width: 44)
                .multilineTextAlignment(.trailing).monospacedDigit()
                .accessibilityLabel("\(settings.notificationValueBasis.label) 알림 기준 퍼센트")
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}
