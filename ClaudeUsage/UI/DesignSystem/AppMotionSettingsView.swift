import SwiftUI

struct AppMotionSettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewCategory: AppMotionCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.row) {
            Label("모션", systemImage: "sparkles").font(AppDesign.Typography.headline)
            Picker("전체 모션", selection: $settings.motion.mode) {
                ForEach(AppMotionMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("즉시는 바로 바뀌고, 부드러움은 중간 움직임을 보여줍니다. 미리보기에서 두 방식을 비교하세요.")
                .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
            ForEach(AppMotionCategory.allCases, id: \.rawValue) { category in
                HStack(spacing: AppDesign.Space.row) {
                    VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                        Text(category.title).font(AppDesign.Typography.subheadline)
                        Text(category.exampleDescription)
                            .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: AppDesign.Space.row)
                    if settings.motion.mode == .custom {
                        Toggle(
                            "부드럽게",
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
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(category.title) 부드럽게")
                    }
                    Button(previewCategory == category ? "닫기" : "미리보기") {
                        previewCategory = previewCategory == category ? nil : category
                    }
                    .controlSize(.small)
                    .accessibilityLabel("\(category.title) 미리보기 \(previewCategory == category ? "닫기" : "열기")")
                }
                .padding(.vertical, AppDesign.Space.compact)
                if previewCategory == category {
                    AppMotionComparisonView(category: category).id(category)
                }
            }
            Text(
                reduceMotion
                    ? "macOS의 ‘동작 줄이기’가 켜져 있어 미리보기를 포함해 즉시 표시합니다. 선택한 설정은 유지됩니다."
                    : "미리보기는 눌렀을 때만 재생되며 설정을 바꾸지 않습니다. 로딩 표시는 작업 중에 계속 움직입니다."
            )
            .font(AppDesign.Typography.caption).foregroundStyle(.secondary)
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
