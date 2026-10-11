import Foundation

/// 활성 provider와 menu bar 선택을 하나의
/// persistence 경계에서 관리한다. `AppSettings`는 기존 호출부를 위한
/// compatibility facade만 제공한다.
@MainActor
final class ProviderSelectionPreferencesStore {
    private static let migrationVersionKey =
        "providerStateMigrationVersion"
    private static let currentMigrationVersion = 1

    private let defaults: UserDefaults

    private(set) var providerStates: AppProviderStateCatalog
    private(set) var menuBarActiveServiceRawValue: String

    init(defaults: UserDefaults) {
        self.defaults = defaults

        let storedActiveService = defaults.string(forKey: "menuBarActiveService") ?? PopoverService.claude.rawValue
        let normalizedActiveService =
            PopoverService(rawValue: storedActiveService.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())?
            .rawValue ?? PopoverService.claude.rawValue
        let legacyStates = AppProviderStateCatalog.fromLegacy(
            claudeEnabled: defaults.object(forKey: "claudeEnabled") as? Bool ?? true,
            codexEnabled: defaults.object(forKey: "codexEnabled") as? Bool ?? false,
            activeService: normalizedActiveService)

        let storedData = defaults.data(forKey: "providerStates")
        // 읽지 못한 저장값은 새 버전이 쓴 것일 수 있어 덮어쓰지 않는다. 사용자가 서비스 설정을 바꿀 때만 다시 쓴다.
        providerStates =
            storedData.flatMap { try? JSONDecoder().decode(AppProviderStateCatalog.self, from: $0) } ?? legacyStates
        menuBarActiveServiceRawValue = normalizedActiveService
        if storedData == nil { persistProviderStates(providerStates) }
        migrateLegacyFieldsIfNeeded(from: providerStates)
    }

    func setProviderStates(
        _ value: AppProviderStateCatalog
    ) {
        providerStates = value
        persistProviderStates(value)
    }

    func setMenuBarActiveServiceRawValue(
        _ value: String
    ) {
        menuBarActiveServiceRawValue = value
        defaults.set(
            value,
            forKey: "menuBarActiveService"
        )
    }

    private func persistProviderStates(
        _ value: AppProviderStateCatalog
    ) {
        if let data = try? JSONEncoder().encode(
            value
        ) {
            defaults.set(
                data,
                forKey: "providerStates"
            )
        }
        defaults.set(
            value.state(for: .claude).isEnabled,
            forKey: "claudeEnabled"
        )
        defaults.set(
            value.state(for: .codex).isEnabled,
            forKey: "codexEnabled"
        )
    }

    private func migrateLegacyFieldsIfNeeded(
        from value: AppProviderStateCatalog
    ) {
        let storedVersion = defaults.integer(
            forKey: Self.migrationVersionKey
        )
        guard storedVersion
                < Self.currentMigrationVersion
        else {
            return
        }

        defaults.set(
            value.state(for: .claude).isEnabled,
            forKey: "claudeEnabled"
        )
        defaults.set(
            value.state(for: .codex).isEnabled,
            forKey: "codexEnabled"
        )
        defaults.set(
            value.legacyMenuBarActiveService(
                fallback:
                    PopoverService.claude.rawValue
            ),
            forKey: "menuBarActiveService"
        )
        defaults.set(
            Self.currentMigrationVersion,
            forKey: Self.migrationVersionKey
        )
    }
}
