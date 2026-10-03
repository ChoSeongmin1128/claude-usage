import Foundation

/// 업데이트 안내에 한 번만 덧붙일 조건부 문구(예: 설정을 합치면서 값이 바뀐 경우).
/// 안내를 보여주면 비운다.
nonisolated enum UpdateNotesQueue {
    static let key = AppIdentifiers.defaultsKey("pendingUpdateNotes")

    enum Note: String, Sendable {
        case timeFormatUnified
    }

    static func enqueue(_ note: Note, defaults: UserDefaults = .standard) {
        var notes = pending(defaults: defaults)
        guard !notes.contains(note) else { return }
        notes.append(note)
        defaults.set(notes.map(\.rawValue), forKey: key)
    }

    static func pending(defaults: UserDefaults = .standard) -> [Note] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(Note.init(rawValue:))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// 2.8.0에서 서비스별 시간 형식을 하나로 합친다. 값이 모두 같으면 그대로 두고,
/// 다르면 Claude 값을 쓰고 업데이트 안내에 한 줄을 남긴다.
nonisolated enum TimeFormatUnification {
    static func migrate(defaults: UserDefaults) {
        let codex = defaults.string(forKey: "codexTimeFormat")
        let antigravity = antigravityTimeFormat(defaults: defaults)
        guard codex != nil || antigravity != nil else { return }
        let claude = defaults.string(forKey: "timeFormat") ?? TimeFormatStyle.h24.rawValue
        if [codex, antigravity].compactMap({ $0 }).contains(where: { $0 != claude }) {
            UpdateNotesQueue.enqueue(.timeFormatUnified, defaults: defaults)
        }
    }

    private static func antigravityTimeFormat(defaults: UserDefaults) -> String? {
        guard let data = defaults.data(forKey: AntigravitySettingsMigrationKeys.displaySettings),
            let settings = try? JSONDecoder().decode(AntigravityDisplaySettings.self, from: data)
        else { return nil }
        return settings.menuBar.timeFormat.rawValue
    }
}
