import SwiftUI

struct NotificationProviderRow: View {
    @ObservedObject var settings: AppSettings
    let provider: AppProviderKind
    let limits: [UsageLimit]
    @Binding var isEnabled: Bool
    @State private var isExpanded = false

    private var service: PopoverService { provider.runtimeService ?? .claude }
    private var selectedIDs: Set<String> { settings.notificationTargets.providers[service.rawValue]?.selectedIDs ?? [] }

    var body: some View {
        HStack(alignment: .top, spacing: AppDesign.Space.control) {
            Toggle("\(provider.displayName) 알림", isOn: $isEnabled)
                .toggleStyle(.checkbox).labelsHidden().padding(.top, AppDesign.Space.row)
            SettingsDisclosureControl(isExpanded: $isExpanded, accessibilityLabel: "\(provider.displayName) 알림 대상") {
                HStack(spacing: AppDesign.Space.row) {
                    ProviderBrandIconView(provider: provider, kind: .settings, size: 16)
                    Text(provider.displayName).font(AppDesign.Typography.subheadline.weight(.semibold))
                    Text(summary).font(AppDesign.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } content: {
                if limits.isEmpty {
                    Text("사용량 조회 후 제공되는 한도를 선택할 수 있습니다.")
                        .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: AppDesign.Space.control) {
                        ForEach(limits) { limit in
                            Toggle(
                                isOn: Binding(
                                    get: { selectedIDs.contains(limit.id) },
                                    set: { settings.notificationTargets.setSelected($0, limit: limit) }
                                )
                            ) {
                                HStack(spacing: AppDesign.Space.control) {
                                    Text(limit.title)
                                    if !limit.isIdentifiable {
                                        Text("식별 정보 확인 필요").foregroundStyle(.secondary)
                                    } else if limit.usedPercentage == nil {
                                        Text("현재 미제공").foregroundStyle(.secondary)
                                    }
                                }
                                .font(AppDesign.Typography.caption)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(
                                !isEnabled || !limit.isIdentifiable
                                    || (!limit.canNotify && !selectedIDs.contains(limit.id)))
                        }
                        let missing = selectedIDs.subtracting(Set(limits.map(\.id))).count
                        if missing > 0 {
                            Text("현재 제공되지 않은 선택 \(missing)개도 보존하고 있습니다.")
                                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        guard !limits.isEmpty else { return "조회 후 선택" }
        let selected = limits.filter { selectedIDs.contains($0.id) }
        if selected.isEmpty { return selectedIDs.isEmpty ? "선택 없음" : "선택 \(selectedIDs.count)개 · 현재 미제공" }
        let names = selected.prefix(2).map(\.title).joined(separator: " · ")
        return selected.count > 2 ? names + " 외 \(selected.count - 2)개" : names
    }
}
