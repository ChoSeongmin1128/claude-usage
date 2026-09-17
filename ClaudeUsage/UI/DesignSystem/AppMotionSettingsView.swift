import SwiftUI

struct AppMotionSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            Label("모션", systemImage: "sparkles").font(AppDesign.Typography.headline)
            Picker("전체 모션", selection: $settings.motion.mode) {
                ForEach(AppMotionMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.motion.mode == .custom {
                ForEach(AppMotionCategory.allCases, id: \.rawValue) { category in
                    Toggle(
                        category.title,
                        isOn: Binding(
                            get: { settings.motion.enabledCategories.contains(category) },
                            set: { enabled in
                                if enabled {
                                    settings.motion.enabledCategories.insert(category)
                                } else {
                                    settings.motion.enabledCategories.remove(category)
                                }
                            }))
                }
                Text("켜진 항목은 부드럽게, 꺼진 항목은 즉시 전환합니다.")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
            Text(
                reduceMotion
                    ? "macOS의 ‘동작 줄이기’가 켜져 있어 현재 모든 전환을 즉시 표시합니다. 선택한 설정은 유지됩니다."
                    : "앱의 화면 전환에 적용합니다. 로딩 표시는 작업이 진행 중임을 계속 알려줍니다."
            )
            .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
        }
    }
}

extension AppMotionPreferences {
    func animation(for category: AppMotionCategory, reduceMotion: Bool) -> Animation? {
        guard allows(category, reduceMotion: reduceMotion) else { return nil }
        return category == .usageValue ? AppDesign.Motion.value : AppDesign.Motion.control
    }
}
