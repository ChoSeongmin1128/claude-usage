import Combine
import SwiftUI

@MainActor
final class NotificationThresholdEditorModel: ObservableObject {
    @Published private(set) var orderedRuleIDs: [String]
    @Published private(set) var drafts: [String: String]
    @Published private(set) var invalidRuleIDs: Set<String> = []

    private var basis: UsageValueBasis

    init(settings: AppSettings) {
        let initialBasis = settings.notificationValueBasis
        basis = initialBasis
        orderedRuleIDs = settings.sortedNotificationPresets.map(\.id)
        drafts = Dictionary(
            uniqueKeysWithValues: settings.notificationPresets.map {
                ($0.id, Self.displayText(for: $0, basis: initialBasis))
            }
        )
    }

    func draftValue(for id: String, settings: AppSettings) -> String {
        if let draft = drafts[id] {
            return draft
        }
        guard let preset = settings.notificationPresets.first(where: { $0.id == id }) else {
            return ""
        }
        return Self.displayText(for: preset, basis: basis)
    }

    func setDraft(_ value: String, for id: String) {
        drafts[id] = value
        invalidRuleIDs.remove(id)
    }

    func syncRules(settings: AppSettings) {
        let currentIDs = Set(settings.notificationPresets.map(\.id))
        orderedRuleIDs.removeAll { !currentIDs.contains($0) }

        let existing = Set(orderedRuleIDs)
        let newIDs = settings.sortedNotificationPresets.map(\.id).filter { !existing.contains($0) }
        orderedRuleIDs.append(contentsOf: newIDs)

        for preset in settings.notificationPresets where drafts[preset.id] == nil {
            drafts[preset.id] = Self.displayText(for: preset, basis: basis)
        }
        drafts = drafts.filter { currentIDs.contains($0.key) }
        invalidRuleIDs.formIntersection(currentIDs)
    }

    func rebase(settings: AppSettings) {
        basis = settings.notificationValueBasis
        orderedRuleIDs = settings.sortedNotificationPresets.map(\.id)
        drafts = Dictionary(
            uniqueKeysWithValues: settings.notificationPresets.map {
                ($0.id, Self.displayText(for: $0, basis: basis))
            }
        )
        invalidRuleIDs.removeAll()
    }

    @discardableResult
    func commit(id: String, settings: AppSettings) -> Bool {
        guard basis == settings.notificationValueBasis else {
            rebase(settings: settings)
            return false
        }
        guard let raw = drafts[id],
            let displayed = Self.parseDisplayedThreshold(raw, basis: basis)
        else {
            invalidRuleIDs.insert(id)
            return false
        }

        settings.setDisplayedNotificationThreshold(displayed, id: id, basis: basis)
        guard let committed = settings.notificationPresets.first(where: { $0.id == id }) else {
            invalidRuleIDs.insert(id)
            return false
        }

        drafts[id] = Self.displayText(for: committed, basis: basis)
        invalidRuleIDs.remove(id)
        return true
    }

    func cancel(id: String, settings: AppSettings) {
        guard let preset = settings.notificationPresets.first(where: { $0.id == id }) else {
            drafts.removeValue(forKey: id)
            invalidRuleIDs.remove(id)
            return
        }
        basis = settings.notificationValueBasis
        drafts[id] = Self.displayText(for: preset, basis: basis)
        invalidRuleIDs.remove(id)
    }

    func commitAllValid(settings: AppSettings) {
        guard basis == settings.notificationValueBasis else {
            rebase(settings: settings)
            return
        }
        for id in orderedRuleIDs {
            guard let raw = drafts[id],
                Self.parseDisplayedThreshold(raw, basis: basis) != nil
            else {
                continue
            }
            _ = commit(id: id, settings: settings)
        }
    }

    func isInvalid(_ id: String) -> Bool {
        invalidRuleIDs.contains(id)
    }

    static func parseDisplayedThreshold(
        _ raw: String,
        basis: UsageValueBasis
    ) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.allSatisfy(\.isNumber),
            let value = Int(trimmed)
        else {
            return nil
        }

        switch basis {
        case .used:
            return (1...100).contains(value) ? value : nil
        case .remaining:
            return (0...99).contains(value) ? value : nil
        }
    }

    private static func displayText(
        for preset: NotificationPreset,
        basis: UsageValueBasis
    ) -> String {
        String(basis == .remaining ? 100 - preset.threshold : preset.threshold)
    }
}

struct NotificationThresholdEditor: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var editor: NotificationThresholdEditorModel
    @FocusState private var focusedRuleID: String?

    init(settings: AppSettings) {
        self.settings = settings
        _editor = StateObject(
            wrappedValue: NotificationThresholdEditorModel(settings: settings)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.control) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesign.Space.content) {
                    rules
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: AppDesign.Space.row) {
                    rules
                }
            }
            Text(
                settings.notificationValueBasis == .remaining
                    ? "이하 남았을 때 알립니다."
                    : "이상 사용했을 때 알립니다."
            )
            .font(AppDesign.Typography.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            editor.rebase(settings: settings)
        }
        .onChange(of: focusedRuleID) { oldValue, _ in
            if let oldValue {
                _ = editor.commit(id: oldValue, settings: settings)
            }
        }
        .onChange(of: settings.notificationValueBasis) { _, _ in
            focusedRuleID = nil
            editor.rebase(settings: settings)
        }
        .onChange(of: settings.notificationPresets.map(\.id)) { _, _ in
            editor.syncRules(settings: settings)
        }
        .onDisappear {
            editor.commitAllValid(settings: settings)
        }
    }

    private var rules: some View {
        ForEach(editor.orderedRuleIDs, id: \.self) { id in
            if let preset = settings.notificationPresets.first(where: { $0.id == id }) {
                rule(preset)
            }
        }
    }

    private func rule(_ preset: NotificationPreset) -> some View {
        let id = preset.id
        return HStack(spacing: AppDesign.Space.control) {
            Toggle(
                "알림",
                isOn: Binding(
                    get: {
                        settings.notificationPresets
                            .first(where: { $0.id == id })?
                            .isEnabled ?? false
                    },
                    set: { enabled in
                        guard let index = settings.notificationPresets.firstIndex(where: { $0.id == id }) else {
                            return
                        }
                        settings.notificationPresets[index].isEnabled = enabled
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(
                "\(settings.notificationValueBasis.label) \(settings.displayedNotificationThreshold(preset))퍼센트 알림"
            )

            TextField(
                "퍼센트",
                text: Binding(
                    get: {
                        editor.draftValue(for: id, settings: settings)
                    },
                    set: {
                        editor.setDraft($0, for: id)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focusedRuleID, equals: id)
            .onSubmit {
                _ = editor.commit(id: id, settings: settings)
            }
            .onExitCommand {
                editor.cancel(id: id, settings: settings)
                focusedRuleID = nil
            }
            .overlay {
                if editor.isInvalid(id) {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.red, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .help(editor.isInvalid(id) ? validRangeHelp : "")
            .accessibilityLabel("\(settings.notificationValueBasis.label) 알림 기준 퍼센트")

            Text("%")
                .foregroundStyle(.secondary)
        }
    }

    private var validRangeHelp: String {
        settings.notificationValueBasis == .remaining
            ? "0~99 사이의 숫자를 입력하세요."
            : "1~100 사이의 숫자를 입력하세요."
    }
}
