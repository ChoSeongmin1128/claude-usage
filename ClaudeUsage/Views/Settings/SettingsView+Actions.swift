import Foundation

extension SettingsView {
    func handleLogoutAction() {
        sessionKeyPersistTask?.cancel()
        sessionKeyPersistTask = nil
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        onLogout?()
        storedSessionKey = nil
        lastVerifiedSessionKey = nil
        sessionKey = ""
        testResult = nil
        organizations = []
        organizationPreviews = [:]
        organizationOAuthFallbackSummary = nil
        organizationMessage = "로그아웃되었습니다. 다시 로그인하거나 브라우저 로그인 값을 입력해 주세요."
    }

    func syncStoredSessionKeyState() {
        sessionKeyPersistTask?.cancel()
        sessionKeyPersistTask = nil
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        if let key = KeychainManager.shared.load() {
            storedSessionKey = key
            sessionKey = key
        } else {
            storedSessionKey = nil
            sessionKey = ""
        }
        lastVerifiedSessionKey = nil
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
                let _ = try await service.fetchUsage()
                await MainActor.run {
                    lastVerifiedSessionKey = normalizedKey
                    testResult = .success("연결 확인됨")
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

    func scheduleSessionKeyPersistence() {
        sessionKeyPersistTask?.cancel()
        sessionKeyPersistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            persistSessionKeyImmediately()
        }
    }

    func flushPendingSessionKeyPersistence() {
        sessionKeyPersistTask?.cancel()
        sessionKeyPersistTask = nil
        persistSessionKeyImmediately()
    }

    func schedulePreferredOrganizationPersistence() {
        organizationPersistTask?.cancel()
        organizationPersistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistPreferredOrganizationSelection()
            loadUsageHealthSnapshot()
        }
    }

    func flushPendingOrganizationPersistence() {
        organizationPersistTask?.cancel()
        organizationPersistTask = nil
        persistPreferredOrganizationSelection()
    }

    func persistSessionKeyImmediately() {
        let normalizedKey = normalizeSessionKey(sessionKey)
        if normalizedKey != sessionKey {
            sessionKey = normalizedKey
        }

        if !normalizedKey.isEmpty {
            let existingKey = normalizeSessionKey(storedSessionKey ?? "")
            if existingKey != normalizedKey {
                do {
                    try KeychainManager.shared.save(normalizedKey)
                    storedSessionKey = normalizedKey
                    lastVerifiedSessionKey = normalizedKey
                } catch {
                    Logger.error("세션 키 저장 실패: \(error)")
                }
            }
        } else {
            try? KeychainManager.shared.delete()
            storedSessionKey = nil
            lastVerifiedSessionKey = nil
            testResult = nil
        }
    }

    func persistPreferredOrganizationSelection() {
        let normalizedOrganizationID = normalizeOrganizationID(selectedOrganizationID)
        if normalizedOrganizationID != selectedOrganizationID {
            selectedOrganizationID = normalizedOrganizationID
        }
        if settings.preferredOrganizationID != normalizedOrganizationID {
            settings.preferredOrganizationID = normalizedOrganizationID
        }
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
        let normalizedKey: String = {
            if !sessionKey.isEmpty {
                return normalizeSessionKey(sessionKey)
            }
            if let storedSessionKey, !storedSessionKey.isEmpty {
                return normalizeSessionKey(storedSessionKey)
            }
            return ""
        }()

        guard !normalizedKey.isEmpty else {
            organizationMessage = hasOAuthCredential
                ? "브라우저 로그인 값이 없어 조직 목록은 건너뜁니다. 지금은 Claude Code 로그인 기준 상태만 확인할 수 있습니다."
                : "브라우저 로그인 값이 없어 조직 목록을 불러올 수 없습니다."
            loadUsageHealthSnapshot()
            return
        }

        isLoadingOrganizations = true
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil

        Task {
            let service = ClaudeAPIService(sessionKey: normalizedKey)
            var resolvedOrganizations: [ClaudeAPIService.OrganizationSummary] = []

            if !forceRefresh {
                let cachedOrganizations = await service.cachedOrganizationsForDisplay()
                if !cachedOrganizations.isEmpty {
                    await MainActor.run {
                        organizations = cachedOrganizations
                        organizationPreviews = [:]
                        isLoadingOrganizations = false
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "저장된 조직 \(cachedOrganizations.count)개를 표시합니다. 바뀌었으면 강제 새로고침을 눌러 주세요."
                        loadUsageHealthSnapshot()
                    }
                    let previews = await service.fetchOrganizationPreviews(for: cachedOrganizations)
                    await MainActor.run {
                        organizationPreviews = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
                    }
                    return
                }
            }

            do {
                resolvedOrganizations = try await service.fetchOrganizations()
            } catch {
                resolvedOrganizations = await service.cachedOrganizationsForDisplay()
                await MainActor.run {
                    if !resolvedOrganizations.isEmpty {
                        organizationMessage = "조직 목록을 불러오지 못해 저장된 목록을 대신 표시합니다."
                    }
                }
            }

            await MainActor.run {
                organizations = resolvedOrganizations
                organizationPreviews = [:]
                isLoadingOrganizations = false
                organizationOAuthFallbackSummary = nil
            }

            guard !resolvedOrganizations.isEmpty else {
                do {
                    let fallbackUsage = try await service.fetchUsage()
                    await MainActor.run {
                        organizationMessage = "조직 목록을 불러오지 못해 Claude Code 로그인 기준 사용량만 표시합니다."
                        let fiveHour = String(format: "%.0f%%", fallbackUsage.fiveHour.utilization)
                        let weekly = String(format: "%.0f%%", fallbackUsage.sevenDay?.utilization ?? 0)
                        organizationOAuthFallbackSummary = "Claude Code 로그인 기준: 현재 \(fiveHour) · 주간 \(weekly)"
                    }
                } catch {
                    await MainActor.run {
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "조직 목록을 불러오지 못했습니다: \(error.localizedDescription)"
                    }
                }
                await MainActor.run {
                    loadUsageHealthSnapshot()
                }
                return
            }

            let previews = await service.fetchOrganizationPreviews(for: resolvedOrganizations)
            let overageEnabledCount = previews.filter { $0.overageEnabled == true }.count

            await MainActor.run {
                organizationPreviews = Dictionary(uniqueKeysWithValues: previews.map { ($0.id, $0) })
                let exists = selectedOrganizationID.isEmpty || resolvedOrganizations.contains { $0.id == selectedOrganizationID }
                if !exists {
                    organizationMessage = "현재 선택한 조직이 목록에 없어 자동 선택으로 동작합니다."
                    return
                }

                if overageEnabledCount > 0 {
                    organizationMessage = "조직 \(resolvedOrganizations.count)개를 불러왔습니다. 추가 사용량 활성 조직 \(overageEnabledCount)개가 있습니다."
                } else {
                    organizationMessage = "조직 \(resolvedOrganizations.count)개를 불러왔습니다."
                }
                loadUsageHealthSnapshot()
            }
        }
    }

    func loadUsageHealthSnapshot() {
        Task {
            let service = ClaudeAPIService()
            await service.updatePreferredOrganizationID(settings.preferredOrganizationID)
            async let snapshot = service.fetchUsageHealthSnapshot()
            async let metadata = service.fetchCachedProfileMetadata()
            let resolvedSnapshot = await snapshot
            let resolvedMetadata = await metadata
            await MainActor.run {
                usageHealthSnapshot = resolvedSnapshot
                profileMetadata = resolvedMetadata
            }
        }
    }

    func resetClaudeAuthDisclosureState() {
        guard !settings.shouldRevealClaudeAdvancedAuth else { return }
        isAdvancedAuthExpanded = false
        isOrganizationAdvancedExpanded = false
    }

    func resetToDefaults() {
        settings.resetToDefaults()
        selectedOrganizationID = settings.preferredOrganizationID
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil
        isOrganizationAdvancedExpanded = false
        checkCodexAuth()
    }
}
