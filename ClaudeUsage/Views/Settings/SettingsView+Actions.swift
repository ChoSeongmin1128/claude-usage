import Foundation

extension SettingsView {
    func handleClearBrowserSessionAction() {
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        cancelOrganizationLoad(clearState: true)
        selectedOrganizationID = ""
        onClearBrowserSession?()
        storedSessionKey = nil
        lastVerifiedSessionKey = nil
        sessionKey = ""
        testResult = nil
        claudeAccountMessage = hasOAuthCredential
            ? "브라우저 로그인 값은 삭제했습니다. Claude Code 로그인이 감지되어 있으면 계속 사용할 수 있습니다."
            : "브라우저 로그인 값은 삭제했습니다. 다시 가져오거나 Claude Code 로그인을 사용해 주세요."
    }

    func showClaudeCodeLoginGuidance() {
        claudeAccountMessage = "Claude Code 로그인을 다시 진행하려면 터미널에서 `claude login`을 실행한 뒤 사용량 새로고침을 눌러 주세요."
    }

    func syncStoredSessionKeyState() {
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        cancelOrganizationLoad()
        ClaudeAccountStore.shared.ensureLegacyMigrationIfNeeded()
        if let account = ClaudeAccountStore.shared.activeWebAccount(),
           let key = KeychainManager.shared.load(for: account.id) {
            storedSessionKey = key
            sessionKey = key
        } else {
            storedSessionKey = nil
            sessionKey = ""
        }
        lastVerifiedSessionKey = nil
    }

    func syncClaudeAccountsState() {
        let state = ClaudeAccountStore.shared.state()
        claudeAccounts = state.accounts
        activeClaudeAccountID = state.activeAccountID
        if state.accounts.isEmpty {
            isClaudeAccountSwitcherExpanded = false
            isClaudeAccountManagementExpanded = false
        } else if state.accounts.count <= 1 {
            isClaudeAccountSwitcherExpanded = false
        }
    }

    func cancelOrganizationLoad(clearState: Bool = false) {
        organizationLoadTask?.cancel()
        organizationLoadTask = nil
        organizationLoadToken = nil
        isLoadingOrganizations = false
        if clearState {
            organizations = []
            organizationPreviews = [:]
        }
    }

    func isCurrentOrganizationLoad(token: UUID, accountID: String) -> Bool {
        organizationLoadToken == token && activeClaudeAccountID == accountID
    }

    func finishOrganizationLoad(token: UUID, accountID: String) {
        guard isCurrentOrganizationLoad(token: token, accountID: accountID) else { return }
        organizationLoadTask = nil
        organizationLoadToken = nil
        isLoadingOrganizations = false
    }

    func testConnection() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        guard !normalizedKey.isEmpty else { return }
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }
        isTesting = true
        testResult = nil

        Task {
            do {
                let service = ClaudeAPIService(sessionKey: normalizedKey)
                await service.updatePreferredOrganizationID(normalizeOrganizationID(selectedOrganizationID))
                let _ = try await service.validateCurrentSessionUsage()
                await MainActor.run {
                    lastVerifiedSessionKey = normalizedKey
                    testResult = .success("연결 확인됨. 저장을 눌러 반영하세요.")
                    isTesting = false
                    loadUsageHealthSnapshot()
                }
            } catch {
                await MainActor.run {
                    lastVerifiedSessionKey = nil
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                    loadUsageHealthSnapshot()
                }
            }
        }
    }

    func schedulePreferredOrganizationPersistence() {
        organizationPersistTask?.cancel()
        organizationPersistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if persistPreferredOrganizationSelection() {
                organizationMessage = "조직을 변경했습니다. 사용량을 다시 조회합니다."
                refreshClaudeUsageFromSettings()
            } else {
                loadUsageHealthSnapshot()
            }
        }
    }

    func flushPendingOrganizationPersistence() {
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        _ = persistPreferredOrganizationSelection()
    }

    func saveVerifiedSessionKey() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }

        guard !normalizedKey.isEmpty,
              normalizedKey == lastVerifiedSessionKey else {
            testResult = .failure("저장 전에 연결 테스트를 먼저 완료해 주세요.")
            return
        }

        let existingKey = normalizeSessionKey(storedSessionKey ?? "")
        guard existingKey != normalizedKey else {
            testResult = .success("이미 저장된 브라우저 로그인 값입니다.")
            return
        }

        do {
            try KeychainManager.shared.save(
                normalizedKey,
                preferredOrganizationID: normalizeOrganizationID(selectedOrganizationID),
                displayName: nil,
                source: .manualInput,
                sourceDetail: nil
            )
            syncClaudeAccountsState()
            storedSessionKey = normalizedKey
            testResult = .success("브라우저 로그인 값을 저장했습니다.")
            loadUsageHealthSnapshot()
        } catch {
            testResult = .failure(error.localizedDescription)
            Logger.error("세션 키 저장 실패: \(error)")
        }
    }

    @discardableResult
    func persistPreferredOrganizationSelection() -> Bool {
        let normalizedOrganizationID = normalizeOrganizationID(selectedOrganizationID)
        if normalizedOrganizationID != selectedOrganizationID {
            selectedOrganizationID = normalizedOrganizationID
        }
        guard let activeClaudeAccountID else { return false }
        let previousOrganizationID = activeClaudeAccount()?.preferredOrganizationID ?? ""
        ClaudeAccountStore.shared.updatePreferredOrganizationID(normalizedOrganizationID, for: activeClaudeAccountID)
        if let organization = organizations.first(where: { $0.id == normalizedOrganizationID }) {
            ClaudeAccountStore.shared.mergeIdentity(
                ClaudeAccountIdentity(
                    organizationName: organization.name,
                    organizationID: organization.id
                ),
                for: activeClaudeAccountID
            )
        }
        syncClaudeAccountsState()
        return previousOrganizationID != normalizedOrganizationID
    }

    func setActiveClaudeAccount(_ account: ClaudeAccount) {
        cancelOrganizationLoad(clearState: true)
        ClaudeAccountStore.shared.setActiveAccountID(account.id)
        syncClaudeAccountsState()
        syncStoredSessionKeyState()
        selectedOrganizationID = appliedPreferredOrganizationID
        claudeAccountMessage = "현재 사용 계정을 \(account.displayName)으로 변경했습니다. 사용량을 다시 조회합니다."
        isClaudeAccountSwitcherExpanded = false
        isClaudeAccountManagementExpanded = false
        loadUsageHealthSnapshot()
    }

    func deleteClaudeWebAccount(_ account: ClaudeAccount) {
        guard account.kind == .webSession else { return }
        cancelOrganizationLoad(clearState: true)
        ClaudeAccountStore.shared.deleteAccount(id: account.id)
        syncClaudeAccountsState()
        syncStoredSessionKeyState()
        selectedOrganizationID = appliedPreferredOrganizationID
        claudeAccountMessage = "브라우저 계정을 삭제했습니다. 외부 Claude Code 로그인은 변경하지 않았습니다."
        if claudeAccounts.count <= 1 {
            isClaudeAccountSwitcherExpanded = false
        }
        if claudeAccounts.isEmpty {
            isClaudeAccountManagementExpanded = false
        }
        loadUsageHealthSnapshot()
    }

    func activeClaudeAccount() -> ClaudeAccount? {
        guard let activeClaudeAccountID else { return nil }
        return claudeAccounts.first(where: { $0.id == activeClaudeAccountID })
    }

    func activeClaudeWebAccount() -> ClaudeAccount? {
        guard let account = activeClaudeAccount(), account.kind == .webSession else { return nil }
        return account
    }

    func activeClaudeWebSessionKey() -> String? {
        guard let account = activeClaudeWebAccount() else { return nil }
        return KeychainManager.shared.load(for: account.id)
    }

    func activeClaudePreferredOrganizationID() -> String {
        activeClaudeWebAccount()?.preferredOrganizationID ?? ""
    }

    func normalizeSessionKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let prefixRange = value.range(of: "sessionKey=", options: [.anchored, .caseInsensitive]) {
            value = String(value[prefixRange.upperBound...])
        }

        if let semiIndex = value.firstIndex(of: ";") {
            value = String(value[..<semiIndex])
        }

        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        return value
    }

    func normalizeOrganizationID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadOrganizations(forceRefresh: Bool = false) {
        guard let loadAccountID = activeClaudeWebAccount()?.id else {
            cancelOrganizationLoad(clearState: true)
            organizationMessage = "조직 선택은 브라우저 계정에서만 사용할 수 있습니다."
            loadUsageHealthSnapshot()
            return
        }

        let normalizedKey: String = {
            if !sessionKey.isEmpty {
                return normalizeSessionKey(sessionKey)
            }
            if let storedSessionKey = activeClaudeWebSessionKey(), !storedSessionKey.isEmpty {
                return normalizeSessionKey(storedSessionKey)
            }
            return ""
        }()

        guard !normalizedKey.isEmpty else {
            cancelOrganizationLoad(clearState: true)
            organizationMessage = "조직 선택은 브라우저 계정에서만 사용할 수 있습니다."
            loadUsageHealthSnapshot()
            return
        }

        cancelOrganizationLoad()
        let loadToken = UUID()
        organizationLoadToken = loadToken
        isLoadingOrganizations = true
        organizationMessage = nil

        organizationLoadTask = Task {
            func shouldApply() async -> Bool {
                if Task.isCancelled { return false }
                return await MainActor.run {
                    isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID)
                }
            }

            let service = ClaudeAPIService(sessionKey: normalizedKey)
            var resolvedOrganizations: [ClaudeAPIService.OrganizationSummary] = []

            if !forceRefresh {
                let cachedOrganizations = await service.cachedOrganizationsForDisplay()
                if !cachedOrganizations.isEmpty {
                    guard await shouldApply() else { return }
                    await MainActor.run {
                        guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                        organizations = cachedOrganizations
                        organizationPreviews = [:]
                        isLoadingOrganizations = false
                        organizationMessage = "저장된 조직 \(cachedOrganizations.count)개를 표시합니다. 바뀌었으면 강제 새로고침을 눌러 주세요."
                        loadUsageHealthSnapshot()
                    }
                    let previews = await service.fetchOrganizationPreviews(for: cachedOrganizations)
                    guard await shouldApply() else { return }
                    await MainActor.run {
                        guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                        organizationPreviews = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
                        finishOrganizationLoad(token: loadToken, accountID: loadAccountID)
                    }
                    return
                }
            }

            do {
                resolvedOrganizations = try await service.fetchOrganizations()
            } catch {
                resolvedOrganizations = await service.cachedOrganizationsForDisplay()
                guard await shouldApply() else { return }
                await MainActor.run {
                    guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                    if !resolvedOrganizations.isEmpty {
                        organizationMessage = "조직 목록을 불러오지 못해 저장된 목록을 대신 표시합니다."
                    }
                }
            }

            guard await shouldApply() else { return }
            await MainActor.run {
                guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                organizations = resolvedOrganizations
                organizationPreviews = [:]
                isLoadingOrganizations = false
            }

            guard !resolvedOrganizations.isEmpty else {
                guard await shouldApply() else { return }
                await MainActor.run {
                    guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                    organizationMessage = "조직 목록을 불러오지 못했습니다. 브라우저 로그인 값을 다시 확인해 주세요."
                    finishOrganizationLoad(token: loadToken, accountID: loadAccountID)
                    loadUsageHealthSnapshot()
                }
                return
            }

            let previews = await service.fetchOrganizationPreviews(for: resolvedOrganizations)
            let overageEnabledCount = previews.filter { $0.overageEnabled == true }.count

            guard await shouldApply() else { return }
            await MainActor.run {
                guard isCurrentOrganizationLoad(token: loadToken, accountID: loadAccountID) else { return }
                organizationPreviews = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
                let exists = selectedOrganizationID.isEmpty || resolvedOrganizations.contains { $0.id == selectedOrganizationID }
                if !exists {
                    organizationMessage = "현재 선택한 조직이 목록에 없어 자동 선택으로 동작합니다."
                    finishOrganizationLoad(token: loadToken, accountID: loadAccountID)
                    return
                }

                if overageEnabledCount > 0 {
                    organizationMessage = "조직 \(resolvedOrganizations.count)개를 불러왔습니다. 추가 사용량 활성 조직 \(overageEnabledCount)개가 있습니다."
                } else {
                    organizationMessage = "조직 \(resolvedOrganizations.count)개를 불러왔습니다."
                }
                finishOrganizationLoad(token: loadToken, accountID: loadAccountID)
                loadUsageHealthSnapshot()
            }
        }
    }

    func loadUsageHealthSnapshot() {
        Task {
            let service = ClaudeAPIService()
            await service.reloadActiveAccount()
            async let snapshot = service.fetchUsageHealthSnapshot()
            async let metadata = service.fetchCachedProfileMetadata()
            async let cachedOrganizations = service.cachedOrganizationsForDisplay()
            let resolvedSnapshot = await snapshot
            let resolvedMetadata = await metadata
            let resolvedCachedOrganizations = await cachedOrganizations
            await MainActor.run {
                usageHealthSnapshot = resolvedSnapshot
                profileMetadata = resolvedMetadata
                claudeAccounts = resolvedSnapshot.accounts
                activeClaudeAccountID = resolvedSnapshot.activeAccountID
                if organizations.isEmpty && !resolvedCachedOrganizations.isEmpty {
                    organizations = resolvedCachedOrganizations
                }
            }
        }
    }

    func refreshClaudeUsageFromSettings() {
        loadUsageHealthSnapshot()
        onRefreshClaudeUsage?()
    }

    func resetClaudeAuthDisclosureState() {
        guard !settings.shouldRevealClaudeAdvancedAuth else { return }
        isClaudeAccountSwitcherExpanded = false
        isClaudeAccountManagementExpanded = false
        isAdvancedAuthExpanded = false
        isOrganizationAdvancedExpanded = false
    }

    func resetToDefaults() {
        settings.resetToDefaults()
        selectedOrganizationID = activeClaudePreferredOrganizationID()
        claudeAccountMessage = nil
        organizationMessage = nil
        isClaudeAccountSwitcherExpanded = false
        isClaudeAccountManagementExpanded = false
        isOrganizationAdvancedExpanded = false
        checkCodexAuth()
    }
}
