import Foundation

/// 새 세션을 가져온 곳. 교체할 때 이 값을 함께 바꿔야 표시 이름, 출처 설명, 브라우저 출처가 어긋나지 않는다.
nonisolated struct ClaudeWebSessionOrigin: Equatable, Sendable {
    var source: ClaudeAccountSource?
    var sourceDetail: String?
    var browserSource: ClaudeBrowserSource?
    var displayName: String?
}

nonisolated extension ClaudeAccount {
    var origin: ClaudeWebSessionOrigin {
        .init(source: source, sourceDetail: sourceDetail, browserSource: browserSource, displayName: displayName)
    }
}

nonisolated extension ClaudeBrowserImportedSession {
    var origin: ClaudeWebSessionOrigin {
        .init(
            source: .chromeProfile, sourceDetail: sourceDetail,
            browserSource: .init(family: family, profileName: profileName), displayName: displayName)
    }
}

nonisolated struct ClaudeWebSessionReplacement: Sendable {
    let store: ClaudeAccountStore
    let vault: any ClaudeSessionKeyVault

    func replace(
        account: ClaudeAccount, sessionKey: String, validation: ClaudeValidatedWebSession,
        origin: ClaudeWebSessionOrigin, expectedPreferences: UsageAccountPreferences,
        previousAccountID: String, expectedActiveAccountID: String? = nil
    ) throws -> ClaudeAccount {
        let newID = ClaudeAccountStore.webSessionAccountID(fingerprint: ClaudeAccountStore.fingerprint(for: sessionKey))
        guard store.canUseAccountID(newID) else { throw APIError.permissionDenied("") }
        let reference = ClaudeKeychainStore.accountName(for: newID)
        let previousKey = try vault.loadString(account: reference)
        guard previousKey == nil || previousKey == sessionKey else { throw APIError.permissionDenied("") }
        do {
            try vault.saveString(sessionKey, account: reference)
            guard try vault.loadString(account: reference) == sessionKey else { throw KeychainError.invalidData }
            try Task.checkCancellation()
            var replacement = account
            replacement.id = newID
            replacement.identity = ClaudeAccountIdentity(
                email: validation.identity.email, organizationName: validation.identity.organizationName,
                organizationID: validation.identity.organizationID, planLabel: account.identity.planLabel,
                fingerprint: ClaudeAccountStore.fingerprint(for: sessionKey))
            replacement.browserSource = origin.browserSource
            replacement.sourceDetail = origin.sourceDetail
            if let source = origin.source { replacement.source = source }
            replacement.displayName =
                origin.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? replacement.identity.primaryLabel
                ?? replacement.displayName
            replacement.lastValidationState = .verified
            replacement.lastUsedAt = Date()
            let preferences = expectedPreferences.replacingWebConnection(
                oldReference: account.id, newReference: newID,
                previousAccountID: previousAccountID, identity: validation.identity)
            guard
                store.replaceWebConnection(
                    expected: account, replacement: replacement,
                    expectedPreferences: expectedPreferences, preferences: preferences,
                    expectedActiveAccountID: expectedActiveAccountID)
            else { throw CancellationError() }
            if account.id != newID { try? vault.delete(account: ClaudeKeychainStore.accountName(for: account.id)) }
            return replacement
        } catch {
            if previousKey == nil, !store.storedAccountIDs().contains(newID) { try? vault.delete(account: reference) }
            throw error
        }
    }
}

nonisolated extension UsageAccountPreferences {
    func mergingAccountID(
        from oldID: String, into destination: String, service: PopoverService,
        inheritVisibility: Bool, keepVisible: Bool
    ) -> Self {
        var updated = self
        if oldID != destination {
            if updated.aliases[destination] == nil { updated.aliases[destination] = updated.aliases[oldID] }
            updated.aliases[oldID] = nil
            if updated.hidden.remove(oldID) != nil, inheritVisibility { updated.hidden.insert(destination) }
            if updated.archived.remove(oldID) != nil, inheritVisibility { updated.archived.insert(destination) }
            func remap(_ values: [String]) -> [String] {
                var seen = Set<String>()
                return values.map { $0 == oldID ? destination : $0 }.filter { seen.insert($0).inserted }
            }
            updated.order = remap(updated.order)
            updated[service].selected = remap(updated[service].selected)
            if updated[service].pinnedTop == oldID { updated[service].pinnedTop = destination }
        }
        if keepVisible { updated.hidden.remove(destination); updated.archived.remove(destination) }
        return updated
    }

    func replacingWebConnection(
        oldReference: String, newReference: String, previousAccountID: String, identity: UsageAccountIdentity
    ) -> Self {
        var updated = self
        let source = UsageAccountSource(role: .web, reference: newReference)
        let destination = UsageAccount.id(service: .claude, identity: identity, source: source)
        for previous in [previousAccountID, "claude:web:\(oldReference)"] {
            updated = updated.mergingAccountID(
                from: previous, into: destination, service: .claude,
                inheritVisibility: false, keepVisible: true)
        }
        if oldReference != newReference { updated.knownIdentities[oldReference] = nil }
        updated.knownIdentities[newReference] = identity
        return updated
    }
}
