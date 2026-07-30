import Foundation

/// Provider 노출 opt-in, 활성 provider, menu bar 선택을 하나의
/// persistence 경계에서 관리한다. `AppSettings`는 기존 호출부를 위한
/// compatibility facade만 제공한다.
@MainActor
final class ProviderSelectionPreferencesStore {
    private static let migrationVersionKey =
        "providerStateMigrationVersion"
    private static let currentMigrationVersion = 1
    private static let additionalProvidersEnabledKey =
        "additionalRuntimeProvidersEnabled"

    private let defaults: UserDefaults

    let loadedProviderStatesFromDisk: Bool
    private(set) var additionalProvidersEnabled:
        Bool
    private(set) var providerStates:
        AppProviderStateCatalog
    private(set) var menuBarActiveServiceRawValue:
        String

    init(defaults: UserDefaults) {
        self.defaults = defaults

        let legacyClaudeEnabled =
            defaults.object(
                forKey: "claudeEnabled"
            ) as? Bool ?? true
        let legacyCodexEnabled =
            defaults.object(
                forKey: "codexEnabled"
            ) as? Bool ?? false
        let storedActiveService =
            defaults.string(
                forKey: "menuBarActiveService"
            ) ?? PopoverService.claude.rawValue
        let normalizedActiveService =
            PopoverService(
                rawValue:
                    storedActiveService
                        .trimmingCharacters(
                            in:
                                .whitespacesAndNewlines
                        )
                        .lowercased()
            )?.rawValue
            ?? PopoverService.claude.rawValue

        let persistedData = defaults.data(
            forKey: "providerStates"
        )
        loadedProviderStatesFromDisk =
            persistedData != nil
        let decoded = persistedData.flatMap {
            try? JSONDecoder().decode(
                AppProviderStateCatalog.self,
                from: $0
            )
        }
        let resolvedStates =
            decoded
            ?? AppProviderStateCatalog.fromLegacy(
                claudeEnabled:
                    legacyClaudeEnabled,
                codexEnabled:
                    legacyCodexEnabled,
                activeService:
                    normalizedActiveService
            )
        providerStates = resolvedStates
        menuBarActiveServiceRawValue =
            normalizedActiveService
        additionalProvidersEnabled =
            Self.inferredAdditionalProvidersEnabled(
                from: defaults,
                decodedProviderStates: decoded,
                legacyCodexEnabled:
                    legacyCodexEnabled,
                activeService:
                    normalizedActiveService
            )

        defaults.set(
            additionalProvidersEnabled,
            forKey:
                Self
                    .additionalProvidersEnabledKey
        )
        persistProviderStates(resolvedStates)
        migrateLegacyFieldsIfNeeded(
            from: resolvedStates
        )
    }

    func setAdditionalProvidersEnabled(
        _ value: Bool
    ) {
        additionalProvidersEnabled = value
        defaults.set(
            value,
            forKey:
                Self
                    .additionalProvidersEnabledKey
        )
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

    static func inferredAdditionalProvidersEnabled(
        from defaults: UserDefaults,
        decodedProviderStates:
            AppProviderStateCatalog?,
        legacyCodexEnabled: Bool,
        activeService: String
    ) -> Bool {
        if let stored = defaults.object(
            forKey:
                Self
                    .additionalProvidersEnabledKey
        ) as? Bool {
            return stored
        }

        if let decodedProviderStates {
            if AppProviderKind.additionalRuntimeKinds
                .contains(
                    where: {
                        decodedProviderStates
                            .state(for: $0)
                            .isEnabled
                    }
                )
            {
                return true
            }
            if let activeKind =
                    decodedProviderStates
                        .activeProviderKind,
               activeKind
                .requiresAdditionalProviderOptIn
            {
                return true
            }
        } else if legacyCodexEnabled {
            return true
        }

        if let activeKind = AppProviderKind(
            rawValue:
                activeService
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .lowercased()
        ) {
            return activeKind
                .requiresAdditionalProviderOptIn
        }
        return false
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
