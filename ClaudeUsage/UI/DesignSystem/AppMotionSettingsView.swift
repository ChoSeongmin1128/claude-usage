import SwiftUI

struct AppMotionSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPreview = false
    @State private var previewCategory = AppMotionCategory.popoverResize

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            HStack {
                Label("모션", systemImage: "sparkles").font(AppDesign.Typography.headline)
                Spacer()
                Button(showsPreview ? "비교 닫기" : "모션 비교") { showsPreview.toggle() }
                    .controlSize(.small)
            }
            Picker("전체 모션", selection: $settings.motion.mode) {
                ForEach(AppMotionMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.motion.mode == .custom {
                VStack(alignment: .leading, spacing: AppDesign.Space.control) {
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
                                })
                        )
                        .toggleStyle(.checkbox).help(category.exampleDescription)
                    }
                }
                Text("선택한 항목만 부드럽게 전환합니다.")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
            if showsPreview {
                Picker("비교할 동작", selection: $previewCategory) {
                    ForEach(AppMotionCategory.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                }
                AppMotionComparisonView(category: previewCategory).id(previewCategory)
            }
            if reduceMotion {
                Text("macOS의 ‘동작 줄이기’가 켜져 있어 즉시 표시합니다. 선택한 설정은 유지됩니다.")
                    .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension AppMotionPreferences {
    func animation(for category: AppMotionCategory, reduceMotion: Bool) -> Animation? {
        guard allows(category, reduceMotion: reduceMotion) else { return nil }
        switch category {
        case .popoverResize: return .easeInOut(duration: AppDesign.Motion.popoverResizeDuration)
        case .usageValue: return AppDesign.Motion.value
        default: return AppDesign.Motion.control
        }
    }
}

extension AppMotionCategory {
    var exampleDescription: String {
        switch self {
        case .popoverPresentation: return "메뉴바 사용량 창이 나타나고 사라질 때"
        case .popoverResize: return "간소화 보기와 일반 보기 사이에서 크기가 바뀔 때"
        case .navigation: return "설정 화면이나 빠른 시작의 다음 단계로 이동할 때"
        case .disclosure: return "계정 상세나 고급 진단을 펼치고 접을 때"
        case .itemChanges: return "표시할 항목의 순서나 개수를 바꿀 때"
        case .usageValue: return "새 조회 결과에 따라 사용량 막대 길이가 바뀔 때"
        }
    }
}
