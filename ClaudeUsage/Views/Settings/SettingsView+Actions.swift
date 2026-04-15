import Foundation

extension SettingsView {
    func handleLogoutAction() {
        onLogout?()
        storedSessionKey = nil
        lastVerifiedSessionKey = nil
        sessionKey = ""
        testResult = nil
        organizations = []
        organizationPreviews = []
        organizationOAuthFallbackSummary = nil
        organizationMessage = "로그아웃되었습니다. 다시 로그인하거나 세션 키를 입력해 주세요."
    }

    func syncStoredSessionKeyState() {
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
                    testResult = .success("연결 확인됨 · 저장은 적용 시점에 진행됩니다")
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

    func runMessagesFallbackTest() {
        guard !isTestingMessagesFallback else { return }
        isTestingMessagesFallback = true
        messagesFallbackStatus = nil

        Task {
            do {
                let service = ClaudeAPIService()
                let usage = try await service.fetchUsageUsingMessagesFallback()
                let fiveHour = String(format: "%.0f%%", usage.fiveHour.utilization)
                let weekly = String(format: "%.0f%%", usage.sevenDay?.utilization ?? 0)
                await MainActor.run {
                    messagesFallbackStatus = "현재 \(fiveHour) · 주간 \(weekly)"
                    isTestingMessagesFallback = false
                    loadUsageHealthSnapshot()
                }
            } catch {
                await MainActor.run {
                    messagesFallbackStatus = "실패: \(error.localizedDescription)"
                    isTestingMessagesFallback = false
                    loadUsageHealthSnapshot()
                }
            }
        }
    }

    func applyChanges() {
        persistChanges()
        onApply?()
    }

    func confirmChanges() {
        persistChanges()
        onSave?()
    }

    func persistChanges() {
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

        if let val = TimeInterval(refreshIntervalText), val >= 5, val <= 120 {
            settings.refreshInterval = val
        }

        let normalizedOrganizationID = normalizeOrganizationID(selectedOrganizationID)
        if normalizedOrganizationID != selectedOrganizationID {
            selectedOrganizationID = normalizedOrganizationID
        }
        settings.preferredOrganizationID = normalizedOrganizationID
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
                ? "세션 키가 없어 organization 목록은 건너뜁니다. 현재는 OAuth 기준 organization 상태만 확인할 수 있습니다."
                : "세션 키가 없어 organization 목록을 불러올 수 없습니다."
            loadUsageHealthSnapshot()
            return
        }

        isLoadingOrganizations = true
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil

        Task {
            let service = ClaudeAPIService(sessionKey: normalizedKey)
            var resolvedOrganizations: [ClaudeAPIService.OrganizationSummary] = []

            if !forceRefresh {
                let cachedOrganizations = await service.cachedOrganizationsForDisplay()
                if !cachedOrganizations.isEmpty {
                    await MainActor.run {
                        let cachedIDs = Set(cachedOrganizations.map(\.id))
                        organizations = cachedOrganizations
                        organizationPreviews = organizationPreviews.filter { cachedIDs.contains($0.id) }
                        isLoadingOrganizations = false
                        isLoadingOrganizationPreviews = false
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "캐시된 organization \(cachedOrganizations.count)개를 표시합니다. 변경 시 강제 새로고침을 눌러주세요."
                        loadUsageHealthSnapshot()
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
                        organizationMessage = "organization 목록 조회 실패로 캐시 목록을 표시합니다."
                    }
                }
            }

            await MainActor.run {
                organizations = resolvedOrganizations
                isLoadingOrganizations = false
                organizationPreviews = []
                organizationOAuthFallbackSummary = nil
            }

            guard !resolvedOrganizations.isEmpty else {
                do {
                    let fallbackUsage = try await service.fetchUsage()
                    await MainActor.run {
                        organizationMessage = "organization 목록 조회 실패로 OAuth 기준 사용량만 표시합니다."
                        let fiveHour = String(format: "%.0f%%", fallbackUsage.fiveHour.utilization)
                        let weekly = String(format: "%.0f%%", fallbackUsage.sevenDay?.utilization ?? 0)
                        organizationOAuthFallbackSummary = "OAuth 기준: 현재 \(fiveHour) · 주간 \(weekly)"
                    }
                } catch {
                    await MainActor.run {
                        organizationOAuthFallbackSummary = nil
                        organizationMessage = "organization 목록 조회 실패: \(error.localizedDescription)"
                    }
                }
                await MainActor.run {
                    loadUsageHealthSnapshot()
                }
                return
            }

            await MainActor.run {
                isLoadingOrganizationPreviews = true
                organizationMessage = "organization \(resolvedOrganizations.count)개 목록을 불러왔습니다. 상세 조회 중..."
            }

            let previews = await service.fetchOrganizationPreviews(for: resolvedOrganizations)
            await MainActor.run {
                organizationPreviews = previews
                isLoadingOrganizationPreviews = false

                let exists = selectedOrganizationID.isEmpty || previews.contains { $0.id == selectedOrganizationID }
                if !exists {
                    organizationMessage = "현재 선택한 organization이 목록에 없어 자동 선택으로 동작합니다."
                    return
                }

                let failedCount = previews.filter { $0.usageErrorMessage != nil }.count
                if failedCount > 0 {
                    organizationMessage = "organization \(previews.count)개 중 \(failedCount)개는 상세 조회에 실패했습니다."
                } else {
                    organizationMessage = "organization \(previews.count)개의 상세를 불러왔습니다."
                }
                loadUsageHealthSnapshot()
            }
        }
    }

    func loadUsageHealthSnapshot() {
        Task {
            let service = ClaudeAPIService()
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

    func formattedMetadataDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    func formattedTimestamp(_ date: Date?) -> String {
        guard let date else { return "기록 없음" }
        let absolute = date.formatted(date: .abbreviated, time: .shortened)
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        let relative = relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(absolute) (\(relative))"
    }

    func shortRelativeTimestamp(_ date: Date?) -> String {
        guard let date else { return "기록 없음" }
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .short
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func updateNotificationPreset(id: String, mutate: (inout NotificationPreset) -> Void) {
        guard let index = settings.notificationPresets.firstIndex(where: { $0.id == id }) else { return }
        var presets = settings.notificationPresets
        mutate(&presets[index])
        settings.notificationPresets = presets
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    func removeNotificationPreset(id: String) {
        guard settings.notificationPresets.count > 1 else { return }
        settings.notificationPresets.removeAll { $0.id == id }
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    func addNotificationPreset() {
        let existing = Set(settings.notificationPresets.map(\.threshold))
        let candidates = [50, 60, 70, 75, 80, 85, 90, 95, 100]
        let next = candidates.first(where: { !existing.contains($0) })
            ?? min((settings.notificationPresets.map(\.threshold).max() ?? 90) + 5, 100)
        settings.notificationPresets.append(NotificationPreset(threshold: next, isEnabled: true))
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
    }

    func resetClaudeAuthDisclosureState() {
        guard !settings.shouldRevealClaudeAdvancedAuth else { return }
        isAdvancedAuthExpanded = false
        isAuthFAQExpanded = false
        isAuthDetailsExpanded = false
        isMessagesFallbackExpanded = false
    }

    func resetToDefaults() {
        settings.resetToDefaults()
        refreshIntervalText = String(Int(settings.refreshInterval))
        alertPresetTexts = settings.sortedNotificationPresets.map { String($0.threshold) }
        selectedOrganizationID = settings.preferredOrganizationID
        organizationPreviews = []
        isLoadingOrganizationPreviews = false
        organizationMessage = nil
        organizationOAuthFallbackSummary = nil
        codexCompactConfigTab = 0
        compactConfigTab = 0
        checkCodexAuth()
    }
}
