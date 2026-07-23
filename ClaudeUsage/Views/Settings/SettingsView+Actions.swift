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
            ? "브라우저 로그인 값은 삭제했습니다. Claude Code 로그인은 그대로 유지했습니다."
            : "브라우저 로그인 값을 삭제했습니다. 이 계정을 다시 사용하려면 Claude.ai 로그인을 연결해 주세요."
    }

    func showClaudeCodeLoginGuidance() {
        claudeAccountMessage = "터미널에서 `claude auth login`을 실행한 뒤 이 화면에서 다시 확인해 주세요."
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
                // ad-hoc 인스턴스로 keychain 저장 없이 일회성 검증만 수행.
                // 영구 저장은 검증 통과 후 saveVerifiedSessionKey() 가 담당한다.
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
        let previousOrganizationID = activeClaudeAccount()?
            .userSelectedPreferredOrganizationID ?? ""
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
        cancelUsageHealthLoad(clearSnapshot: true)
        profileMetadata = nil
        activeClaudeAccountID = account.id
        selectedOrganizationID = account.userSelectedPreferredOrganizationID ?? ""
        claudeAccountMessage = "현재 사용 계정을 \(account.displayName)으로 변경했습니다. 새 계정의 사용량을 확인합니다."
        isClaudeAccountSwitcherExpanded = false
        isClaudeAccountManagementExpanded = false
        ClaudeAccountStore.shared.setActiveAccountID(account.id)
    }

    func deleteClaudeWebAccount(_ account: ClaudeAccount) {
        guard account.kind == .webSession else { return }
        cancelOrganizationLoad(clearState: true)
        cancelUsageHealthLoad(clearSnapshot: true)
        profileMetadata = nil
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
        activeClaudeWebAccount()?.userSelectedPreferredOrganizationID ?? ""
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

            // 활성 계정의 조직 조회는 AppDelegate가 주입한 공용 actor를
            // 사용한다. fetchOrganizations()가 store에서 active account를
            // 다시 로드하므로 계정 전환과 같은 credential 경계를 공유한다.
            let service = claudeAPIService
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

    func cancelUsageHealthLoad(clearSnapshot: Bool = false) {
        usageHealthLoadGeneration &+= 1
        usageHealthLoadTask?.cancel()
        usageHealthLoadTask = nil
        if clearSnapshot {
            usageHealthSnapshot = nil
        }
    }

    func loadUsageHealthSnapshot(refreshOAuthCredentialInventory: Bool = false) {
        cancelUsageHealthLoad()
        let generation = usageHealthLoadGeneration
        let requestedAccountID = ClaudeAccountStore.shared.state().activeAccountID
        let service = claudeAPIService
        usageHealthLoadTask = Task {
            await service.reloadActiveAccount()
            async let snapshot = service.fetchUsageHealthSnapshot(
                refreshOAuthCredentialInventory: refreshOAuthCredentialInventory
            )
            async let metadata = service.fetchCachedProfileMetadata()
            async let cachedOrganizations = service.cachedOrganizationsForDisplay()
            let resolvedSnapshot = await snapshot
            let resolvedMetadata = await metadata
            let resolvedCachedOrganizations = await cachedOrganizations
            let responseAccountID = await service.currentActiveAccountID()
            guard !Task.isCancelled,
                  requestedAccountID == responseAccountID else { return }
            await MainActor.run {
                let currentState = ClaudeAccountStore.shared.state()
                guard generation == usageHealthLoadGeneration,
                      requestedAccountID == currentState.activeAccountID,
                      let resolvedAccountState = ClaudeAccountSnapshotPresentationPolicy.resolve(
                          snapshotActiveAccountID: resolvedSnapshot.activeAccountID,
                          currentState: currentState
                      ) else { return }
                usageHealthSnapshot = resolvedSnapshot
                profileMetadata = resolvedMetadata
                claudeAccounts = resolvedAccountState.accounts
                activeClaudeAccountID = resolvedAccountState.activeAccountID
                if organizations.isEmpty && !resolvedCachedOrganizations.isEmpty {
                    organizations = resolvedCachedOrganizations
                }
                usageHealthLoadTask = nil
            }
        }
    }

    func refreshClaudeUsageFromSettings() {
        onRefreshClaudeUsage?()
    }

    func inspectClaudeOAuthMigration() {
        claudeOAuthMigrationTask?.cancel()
        let coordinator = claudeOAuthMigrationCoordinator
        claudeOAuthMigrationTask = Task {
            let state = await coordinator.inspect()
            guard !Task.isCancelled else { return }
            claudeOAuthMigrationState = state
            claudeOAuthMigrationTask = nil
        }
    }

    func migrateLegacyClaudeOAuthCredential() {
        guard claudeOAuthMigrationState == .available || isClaudeOAuthMigrationFailure else { return }
        claudeOAuthMigrationTask?.cancel()
        claudeOAuthMigrationState = .migrating
        let coordinator = claudeOAuthMigrationCoordinator
        let service = claudeAPIService
        claudeOAuthMigrationTask = Task {
            let state = await coordinator.migrate()
            guard !Task.isCancelled else { return }
            claudeOAuthMigrationState = state
            claudeOAuthMigrationTask = nil
            switch state {
            case .completed, .completedWithLegacyCleanupFailure:
                await service.invalidateClaudeCodeCredentialCache()
                onClaudeOAuthMigrationCompleted?()
            default:
                break
            }
        }
    }

    func deferClaudeOAuthMigration() {
        claudeOAuthMigrationTask?.cancel()
        let coordinator = claudeOAuthMigrationCoordinator
        claudeOAuthMigrationTask = Task {
            claudeOAuthMigrationState = await coordinator.deferForCurrentSession()
            claudeOAuthMigrationTask = nil
        }
    }

    var isClaudeOAuthMigrationFailure: Bool {
        if case .failed = claudeOAuthMigrationState { return true }
        return false
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
