import Foundation

nonisolated enum AntigravitySettingsMigrationKeys {
    static let currentMigrationVersion = 2

    static let connectionSettings = "antigravity.connectionSettings"
    static let displaySettings = "antigravity.displaySettings"
    static let migrationVersion = "antigravity.settingsMigrationVersion"

    static let popoverItemsByProvider = "popoverItemsV2"
    static let compactPopoverItemsByProvider = "compactPopoverItemsV2"

    static let legacyAntigravityKeys = [
        "antigravityUsageDataSource",
        "antigravityHiddenModelIDs",
        "antigravityMenuBarPrimaryModelID",
        "antigravityMenuBarSecondaryModelID",
        "antigravity.showIcon",
        "antigravity.alertEnabled",
        "antigravity.menuBarStyle",
        "antigravity.percentageDisplay",
        "antigravity.resetTimeDisplay",
        "antigravity.timeFormat",
        "antigravity.showBatteryPercent",
        "antigravity.circularDisplayMode",
        "antigravity.iconMetric",
        "antigravityPopoverPinned",
        "antigravityPopoverCompact",
        "antigravitySettingsLastTab",
    ]

    static let removedGeminiKeys = [
        "gemini.alertEnabled",
        "gemini.circularDisplayMode",
        "gemini.iconMetric",
        "gemini.menuBarStyle",
        "gemini.percentageDisplay",
        "gemini.resetTimeDisplay",
        "gemini.showBatteryPercent",
        "gemini.showIcon",
        "gemini.timeFormat",
        "geminiPopoverCompact",
        "geminiPopoverPinned",
        "geminiSettingsLastTab",
    ]

    static let legacyKeys = legacyAntigravityKeys + removedGeminiKeys

    /// 이 coordinator가 한 transaction에서 수정하거나 복구할 수 있는 정확한 key 집합입니다.
    /// 다른 shared setting은 읽거나 쓰지 않습니다.
    static let ownedMutationKeys = [
        connectionSettings,
        displaySettings,
        popoverItemsByProvider,
        compactPopoverItemsByProvider,
    ] + legacyKeys + [
        migrationVersion,
    ]
}

final class AntigravitySettingsMigrationCoordinator {
    nonisolated enum Outcome: Equatable, Sendable {
        case alreadyCurrent
        case migrated(pendingNotice: AntigravitySettingsMigrationNotice?)
        case failed(Failure)
    }

    nonisolated enum NoticeAcknowledgementOutcome:
        Equatable,
        Sendable
    {
        case noPendingNotice
        case consumed(AntigravitySettingsMigrationNotice)
        case failed(Failure)
    }

    nonisolated struct Failure: Equatable, Sendable {
        let reason: FailureReason
        let rollbackCompleted: Bool
    }

    nonisolated enum FailureReason:
        Error,
        Equatable,
        Sendable
    {
        case invalidMigrationMarker
        case unsupportedMigrationVersion(Int)
        case invalidCurrentConnectionSettings
        case invalidCurrentDisplaySettings
        case invalidPopoverSettings(String)
        case encodingFailed(String)
        case writeVerificationFailed(String)
        case deleteVerificationFailed(String)
    }

    private enum StoredSettings<Value> {
        case missing
        case current(Value)
    }

    private enum StoredConnectionSettings {
        case missing
        case current(AntigravityConnectionSettings)
        case legacyV1(LegacyConnectionSettingsV1)
    }

    private struct LegacyConnectionSettingsV1: Decodable {
        enum SourcePolicy: String, Decodable {
            case automatic
            case localSession = "local_session"
            case googleAccount = "google_account"
        }

        let schemaVersion: Int
        let sourcePolicy: SourcePolicy
        let allowManagedCLI: Bool
        let managedSession:
            AntigravityConnectionSettings.ManagedSessionPolicy

        var isValid: Bool {
            schemaVersion == 1
                && managedSession.isValid
        }
    }

    private enum SnapshotValue {
        case absent
        case present(Any)
    }

    private struct PopoverMutation {
        let transformed: [String: [PopoverItemConfig]]?
        let changed: Bool
        let resetModelSelection: Bool
    }

    private static let oldAntigravityPopoverIDs: Set<String> = [
        "antigravityPrimary",
        "antigravitySecondary",
        "antigravityTertiary",
        "antigravityModels",
    ]
    private static let modelSpecificAntigravityPopoverIDs: Set<String> = [
        "antigravityPrimary",
        "antigravitySecondary",
        "antigravityTertiary",
    ]
    private static let newAntigravityPopoverID = "antigravityUsageLimits"

    private let store: AntigravitySettingsMigrationStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        store: AntigravitySettingsMigrationStore,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.store = store
        self.encoder = encoder
        self.decoder = decoder
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(store: UserDefaultsAntigravitySettingsMigrationStore(defaults: defaults))
    }

    func migrate() -> Outcome {
        let markerVersion: Int
        do {
            markerVersion = try readMigrationVersion()
        } catch let reason as FailureReason {
            return .failed(Failure(reason: reason, rollbackCompleted: true))
        } catch {
            return .failed(Failure(reason: .invalidMigrationMarker, rollbackCompleted: true))
        }

        let storedConnection: StoredConnectionSettings
        let storedDisplay: StoredSettings<AntigravityDisplaySettings>
        let fullPopover: PopoverMutation
        let compactPopover: PopoverMutation

        do {
            storedConnection = try readCurrentConnectionSettings()
            storedDisplay = try readCurrentDisplaySettings()
            fullPopover = try readPopoverMutation(
                forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
            )
            compactPopover = try readPopoverMutation(
                forKey: AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider
            )
        } catch let reason as FailureReason {
            return .failed(Failure(reason: reason, rollbackCompleted: true))
        } catch {
            return .failed(Failure(reason: .invalidMigrationMarker, rollbackCompleted: true))
        }

        let hasLegacyKeys = AntigravitySettingsMigrationKeys.legacyKeys.contains {
            store.object(forKey: $0) != nil
        }
        let hasMissingSettings: Bool
        switch (storedConnection, storedDisplay) {
        case (.current, .current),
             (.legacyV1, .current):
            hasMissingSettings = false
        case (.missing, _),
             (_, .missing):
            hasMissingSettings = true
        }

        let requiresMigration = markerVersion != AntigravitySettingsMigrationKeys.currentMigrationVersion
            || {
                if case .legacyV1 = storedConnection {
                    return true
                }
                return false
            }()
            || hasLegacyKeys
            || hasMissingSettings
            || fullPopover.changed
            || compactPopover.changed

        guard requiresMigration else {
            return .alreadyCurrent
        }

        let connection: AntigravityConnectionSettings
        switch storedConnection {
        case let .current(value):
            connection = value
        case let .legacyV1(value):
            connection = AntigravityConnectionSettings(
                schemaVersion:
                    AntigravityConnectionSettings
                        .currentSchemaVersion,
                managedSession: value.managedSession
            )
        case .missing:
            connection = makeConnectionSettings()
        }

        let display: AntigravityDisplaySettings
        switch storedDisplay {
        case let .current(value):
            display = value
        case .missing:
            display = makeDisplaySettings(
                resetModelSelectionFromPopover: fullPopover.resetModelSelection
                    || compactPopover.resetModelSelection
            )
        }

        let snapshot = captureOwnedState()

        do {
            switch storedConnection {
            case .missing, .legacyV1:
                try writeAndVerifyConnection(connection)
            case .current:
                try verifyConnection(connection)
            }

            if case .missing = storedDisplay {
                try writeAndVerifyDisplay(display)
            } else {
                try verifyDisplay(display)
            }

            if fullPopover.changed, let transformed = fullPopover.transformed {
                try writeAndVerifyPopover(
                    transformed,
                    forKey: AntigravitySettingsMigrationKeys.popoverItemsByProvider
                )
            }
            if compactPopover.changed, let transformed = compactPopover.transformed {
                try writeAndVerifyPopover(
                    transformed,
                    forKey: AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider
                )
            }

            try deleteAndVerifyLegacyKeys()
            try verifyNoOldAntigravityPopoverIDs()

            store.set(
                AntigravitySettingsMigrationKeys.currentMigrationVersion,
                forKey: AntigravitySettingsMigrationKeys.migrationVersion
            )
            guard try readMigrationVersion() == AntigravitySettingsMigrationKeys.currentMigrationVersion else {
                throw FailureReason.writeVerificationFailed(
                    AntigravitySettingsMigrationKeys.migrationVersion
                )
            }

            try verifyConnection(connection)
            try verifyDisplay(display)
            try verifyNoOldAntigravityPopoverIDs()

            return .migrated(pendingNotice: display.pendingNotice)
        } catch let reason as FailureReason {
            return .failed(
                Failure(
                    reason: reason,
                    rollbackCompleted: restoreOwnedState(snapshot)
                )
            )
        } catch {
            return .failed(
                Failure(
                    reason: .writeVerificationFailed("unknown"),
                    rollbackCompleted: restoreOwnedState(snapshot)
                )
            )
        }
    }

    func acknowledgePendingNotice() -> NoticeAcknowledgementOutcome {
        let storedDisplay: StoredSettings<AntigravityDisplaySettings>
        do {
            storedDisplay = try readCurrentDisplaySettings()
        } catch let reason as FailureReason {
            return .failed(Failure(reason: reason, rollbackCompleted: true))
        } catch {
            return .failed(
                Failure(
                    reason: .invalidCurrentDisplaySettings,
                    rollbackCompleted: true
                )
            )
        }

        guard case let .current(display) = storedDisplay else {
            return .noPendingNotice
        }
        guard let notice = display.pendingNotice else {
            return .noPendingNotice
        }

        let key = AntigravitySettingsMigrationKeys.displaySettings
        let snapshot = captureState(for: [key])
        var acknowledgedDisplay = display
        acknowledgedDisplay.pendingNotice = nil

        do {
            try writeAndVerifyDisplay(acknowledgedDisplay)
            return .consumed(notice)
        } catch let reason as FailureReason {
            return .failed(
                Failure(
                    reason: reason,
                    rollbackCompleted: restoreState(snapshot, for: [key])
                )
            )
        } catch {
            return .failed(
                Failure(
                    reason: .writeVerificationFailed(key),
                    rollbackCompleted: restoreState(snapshot, for: [key])
                )
            )
        }
    }

    private func readMigrationVersion() throws -> Int {
        guard let object = store.object(forKey: AntigravitySettingsMigrationKeys.migrationVersion) else {
            return 0
        }
        guard let number = object as? NSNumber else {
            throw FailureReason.invalidMigrationMarker
        }

        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw FailureReason.invalidMigrationMarker
        }
        let value = number.intValue
        guard
            number.doubleValue.isFinite,
            number.doubleValue == Double(value),
            value >= 0
        else {
            throw FailureReason.invalidMigrationMarker
        }
        guard value <= AntigravitySettingsMigrationKeys.currentMigrationVersion else {
            throw FailureReason.unsupportedMigrationVersion(value)
        }
        return value
    }

    private func readCurrentConnectionSettings() throws
        -> StoredConnectionSettings
    {
        let key = AntigravitySettingsMigrationKeys.connectionSettings
        guard let object = store.object(forKey: key) else {
            return .missing
        }
        guard let data = object as? Data else {
            throw FailureReason.invalidCurrentConnectionSettings
        }
        if let value = try? decoder.decode(
            AntigravityConnectionSettings.self,
            from: data
        ), value.isCurrentAndValid {
            return .current(value)
        }
        if let value = try? decoder.decode(
            LegacyConnectionSettingsV1.self,
            from: data
        ), value.isValid {
            return .legacyV1(value)
        }
        throw FailureReason.invalidCurrentConnectionSettings
    }

    private func readCurrentDisplaySettings() throws -> StoredSettings<AntigravityDisplaySettings> {
        let key = AntigravitySettingsMigrationKeys.displaySettings
        guard let object = store.object(forKey: key) else {
            return .missing
        }
        guard
            let data = object as? Data,
            let value = try? decoder.decode(AntigravityDisplaySettings.self, from: data),
            value.isCurrentAndValid
        else {
            throw FailureReason.invalidCurrentDisplaySettings
        }
        return .current(value)
    }

    private func makeConnectionSettings() -> AntigravityConnectionSettings {
        return AntigravityConnectionSettings(
            schemaVersion: AntigravityConnectionSettings.currentSchemaVersion,
            managedSession: .default
        )
    }

    private func makeDisplaySettings(
        resetModelSelectionFromPopover: Bool
    ) -> AntigravityDisplaySettings {
        let showIcon = bool(forKey: "antigravity.showIcon", fallback: true)
        let percentage = legacyPercentageIntent()
        let resetTime = legacyResetTimeIntent()
        let style = legacyMenuBarStyle()
        let timeFormat = legacyTimeFormat()
        let showsGaugePercentage = bool(
            forKey: "antigravity.showBatteryPercent",
            fallback: true
        )
        let circularValue = legacyCircularValue()
        let notificationsEnabled = bool(
            forKey: "antigravity.alertEnabled",
            fallback: false
        )

        let isVisible = showIcon
            || percentage.isVisible
            || resetTime.isVisible
            || style.value != .none

        let resetModelSelection = resetModelSelectionFromPopover
            || hasLegacyModelSelection()
            || percentage.resetsModelSelection
            || resetTime.resetsModelSelection
            || style.resetsModelSelection

        return AntigravityDisplaySettings(
            schemaVersion: AntigravityDisplaySettings.currentSchemaVersion,
            standard: .init(laneSelection: .allKnown),
            compact: .init(laneSelection: .automaticMostConstrained),
            menuBar: .init(
                isVisible: isVisible,
                showsProviderIcon: showIcon,
                style: style.value,
                laneSelection: .automaticMostConstrained,
                showsSelectedLanePercentage: percentage.isVisible,
                showsSelectedLaneResetTime: resetTime.isVisible,
                timeFormat: timeFormat,
                showsGaugePercentage: showsGaugePercentage,
                circularValue: circularValue
            ),
            notifications: .init(isEnabled: notificationsEnabled),
            pendingNotice: resetModelSelection ? .displaySelectionUpdated : nil
        )
    }

    private func hasLegacyModelSelection() -> Bool {
        if normalizedString(forKey: "antigravityMenuBarPrimaryModelID") != nil
            || normalizedString(forKey: "antigravityMenuBarSecondaryModelID") != nil {
            return true
        }

        if !legacyStringSet(forKey: "antigravityHiddenModelIDs").isEmpty {
            return true
        }

        guard let rawIconMetric = string(forKey: "antigravity.iconMetric") else {
            return false
        }
        return rawIconMetric == "five_hour" || rawIconMetric == "weekly"
    }

    private func legacyPercentageIntent() -> (isVisible: Bool, resetsModelSelection: Bool) {
        guard let raw = string(forKey: "antigravity.percentageDisplay") else {
            return (true, false)
        }
        switch raw {
        case "pct_none":
            return (false, false)
        case "pct_five_hour", "pct_weekly", "pct_dual":
            return (true, true)
        default:
            return (true, false)
        }
    }

    private func legacyResetTimeIntent() -> (isVisible: Bool, resetsModelSelection: Bool) {
        guard let raw = string(forKey: "antigravity.resetTimeDisplay") else {
            return (false, false)
        }
        switch raw {
        case "five_hour", "weekly", "dual":
            return (true, true)
        case "none":
            return (false, false)
        default:
            return (false, false)
        }
    }

    private func legacyMenuBarStyle() -> (
        value: AntigravityDisplaySettings.MenuBarPresentationIntent.Style,
        resetsModelSelection: Bool
    ) {
        switch string(forKey: "antigravity.menuBarStyle") {
        case "battery_bar":
            return (.batteryBar, false)
        case "circular":
            return (.circular, false)
        case "concentric_rings":
            return (.circular, true)
        case "dual_battery", "side_by_side_battery":
            return (.batteryBar, true)
        case "none", nil:
            return (.none, false)
        default:
            return (.none, false)
        }
    }

    private func legacyTimeFormat() -> AntigravityDisplaySettings.MenuBarPresentationIntent.TimeFormat {
        switch string(forKey: "antigravity.timeFormat") {
        case "12h":
            return .h12
        case "remaining":
            return .remaining
        case "24h", nil:
            return .h24
        default:
            return .h24
        }
    }

    private func legacyCircularValue() -> AntigravityDisplaySettings.MenuBarPresentationIntent.CircularValue {
        switch string(forKey: "antigravity.circularDisplayMode") {
        case "remaining":
            return .remaining
        case "usage", nil:
            return .usage
        default:
            return .usage
        }
    }

    private func readPopoverMutation(forKey key: String) throws -> PopoverMutation {
        guard let object = store.object(forKey: key) else {
            return PopoverMutation(
                transformed: nil,
                changed: false,
                resetModelSelection: false
            )
        }
        guard
            let data = object as? Data,
            var dictionary = try? decoder.decode(
                [String: [PopoverItemConfig]].self,
                from: data
            )
        else {
            throw FailureReason.invalidPopoverSettings(key)
        }

        let providerKey = "antigravity"
        guard let items = dictionary[providerKey] else {
            return PopoverMutation(
                transformed: dictionary,
                changed: false,
                resetModelSelection: false
            )
        }

        let hasOldIDs = items.contains { Self.oldAntigravityPopoverIDs.contains($0.id) }
        guard hasOldIDs else {
            return PopoverMutation(
                transformed: dictionary,
                changed: false,
                resetModelSelection: false
            )
        }

        let replacementVisible = items
            .filter {
                Self.oldAntigravityPopoverIDs.contains($0.id)
                    || $0.id == Self.newAntigravityPopoverID
            }
            .contains(where: \.visible)

        var insertedReplacement = false
        var migratedItems: [PopoverItemConfig] = []
        for item in items {
            let isMigratedItem = Self.oldAntigravityPopoverIDs.contains(item.id)
                || item.id == Self.newAntigravityPopoverID
            if isMigratedItem {
                if !insertedReplacement {
                    migratedItems.append(
                        PopoverItemConfig(
                            id: Self.newAntigravityPopoverID,
                            visible: replacementVisible
                        )
                    )
                    insertedReplacement = true
                }
                continue
            }
            migratedItems.append(item)
        }

        dictionary[providerKey] = migratedItems
        return PopoverMutation(
            transformed: dictionary,
            changed: migratedItems != items,
            resetModelSelection: items.contains {
                Self.modelSpecificAntigravityPopoverIDs.contains($0.id)
            }
        )
    }

    private func writeAndVerifyConnection(
        _ value: AntigravityConnectionSettings
    ) throws {
        let key = AntigravitySettingsMigrationKeys.connectionSettings
        guard let data = try? encoder.encode(value) else {
            throw FailureReason.encodingFailed(key)
        }
        store.set(data, forKey: key)
        try verifyConnection(value)
    }

    private func verifyConnection(
        _ expected: AntigravityConnectionSettings
    ) throws {
        let key = AntigravitySettingsMigrationKeys.connectionSettings
        guard
            let data = store.object(forKey: key) as? Data,
            let stored = try? decoder.decode(AntigravityConnectionSettings.self, from: data),
            stored.isCurrentAndValid,
            stored == expected
        else {
            throw FailureReason.writeVerificationFailed(key)
        }
    }

    private func writeAndVerifyDisplay(
        _ value: AntigravityDisplaySettings
    ) throws {
        let key = AntigravitySettingsMigrationKeys.displaySettings
        guard let data = try? encoder.encode(value) else {
            throw FailureReason.encodingFailed(key)
        }
        store.set(data, forKey: key)
        try verifyDisplay(value)
    }

    private func verifyDisplay(
        _ expected: AntigravityDisplaySettings
    ) throws {
        let key = AntigravitySettingsMigrationKeys.displaySettings
        guard
            let data = store.object(forKey: key) as? Data,
            let stored = try? decoder.decode(AntigravityDisplaySettings.self, from: data),
            stored.isCurrentAndValid,
            stored == expected
        else {
            throw FailureReason.writeVerificationFailed(key)
        }
    }

    private func writeAndVerifyPopover(
        _ value: [String: [PopoverItemConfig]],
        forKey key: String
    ) throws {
        guard let data = try? encoder.encode(value) else {
            throw FailureReason.encodingFailed(key)
        }
        store.set(data, forKey: key)
        guard
            let storedData = store.object(forKey: key) as? Data,
            let stored = try? decoder.decode(
                [String: [PopoverItemConfig]].self,
                from: storedData
            ),
            stored == value
        else {
            throw FailureReason.writeVerificationFailed(key)
        }
    }

    private func deleteAndVerifyLegacyKeys() throws {
        for key in AntigravitySettingsMigrationKeys.legacyKeys {
            store.removeObject(forKey: key)
        }
        for key in AntigravitySettingsMigrationKeys.legacyKeys
        where store.object(forKey: key) != nil {
            throw FailureReason.deleteVerificationFailed(key)
        }
    }

    private func verifyNoOldAntigravityPopoverIDs() throws {
        for key in [
            AntigravitySettingsMigrationKeys.popoverItemsByProvider,
            AntigravitySettingsMigrationKeys.compactPopoverItemsByProvider,
        ] {
            guard let object = store.object(forKey: key) else {
                continue
            }
            guard
                let data = object as? Data,
                let dictionary = try? decoder.decode(
                    [String: [PopoverItemConfig]].self,
                    from: data
                )
            else {
                throw FailureReason.invalidPopoverSettings(key)
            }
            let containsOldID = dictionary["antigravity"]?.contains {
                Self.oldAntigravityPopoverIDs.contains($0.id)
            } ?? false
            if containsOldID {
                throw FailureReason.writeVerificationFailed(key)
            }
        }
    }

    private func captureOwnedState() -> [String: SnapshotValue] {
        captureState(for: AntigravitySettingsMigrationKeys.ownedMutationKeys)
    }

    private func captureState(
        for keys: [String]
    ) -> [String: SnapshotValue] {
        var snapshot: [String: SnapshotValue] = [:]
        for key in keys {
            if let object = store.object(forKey: key) {
                snapshot[key] = .present(object)
            } else {
                snapshot[key] = .absent
            }
        }
        return snapshot
    }

    private func restoreOwnedState(
        _ snapshot: [String: SnapshotValue]
    ) -> Bool {
        restoreState(
            snapshot,
            for: AntigravitySettingsMigrationKeys.ownedMutationKeys
        )
    }

    private func restoreState(
        _ snapshot: [String: SnapshotValue],
        for keys: [String]
    ) -> Bool {
        for key in keys {
            guard let value = snapshot[key] else {
                continue
            }
            switch value {
            case .absent:
                store.removeObject(forKey: key)
            case let .present(object):
                store.set(object, forKey: key)
            }
        }

        return keys.allSatisfy { key in
            let expected: Any?
            switch snapshot[key] {
            case .absent:
                expected = nil
            case let .present(object):
                expected = object
            case nil:
                return false
            }
            return objectsAreEqual(store.object(forKey: key), expected)
        }
    }

    private func objectsAreEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs as NSObject, rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }

    private func string(forKey key: String) -> String? {
        store.object(forKey: key) as? String
    }

    private func normalizedString(forKey key: String) -> String? {
        let value = string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func bool(forKey key: String, fallback: Bool) -> Bool {
        store.object(forKey: key) as? Bool ?? fallback
    }

    private func legacyStringSet(forKey key: String) -> Set<String> {
        guard let object = store.object(forKey: key) else {
            return []
        }

        let values: [String]
        if let data = object as? Data,
           let decoded = try? decoder.decode([String].self, from: data) {
            values = decoded
        } else if let array = object as? [String] {
            values = array
        } else {
            values = []
        }

        return Set(values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        })
    }
}
