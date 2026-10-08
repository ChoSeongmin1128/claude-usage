import Foundation
import XCTest

@testable import ClaudeUsage

@MainActor
final class ClaudeCredentialContextTests: XCTestCase {
    func testFirstObservedTokenChecksPersistedIdentityBeforePublishingUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "B")
        let service = fixture.service(reader: reader) { request in
            Self.response(request, body: request.url!.path.hasSuffix("profile") ? Self.profile("B") : Self.usage(80))
        }

        let result = try await service.fetchUsageOutcome()
        XCTAssertEqual(result.usage.fiveHour?.utilization, 80)
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "B@example.com")
    }

    func testChangedTokenDiscardsOldUsageCacheAndIdentityButUnchangedTokenKeepsCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let history = ContextRequestHistory()
        let service = fixture.service(reader: reader) { request in
            await history.append(request)
            let token = Self.token(request)
            return Self.response(
                request,
                body: request.url!.path.hasSuffix("profile")
                    ? Self.profile(token) : Self.usage(token == "A" ? 10 : 80))
        }
        let first = try await service.fetchUsageOutcome()
        XCTAssertEqual(first.usage.fiveHour?.utilization, 10)
        await service.refreshClaudeCodeAccountProfile()
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "A@example.com")

        await reader.setToken("B")
        let changed = try await service.fetchUsageOutcome()
        XCTAssertEqual(changed.usage.fiveHour?.utilization, 80)
        await service.refreshClaudeCodeAccountProfile()
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "B@example.com")
        let unchanged = try await service.fetchUsageOutcome()
        XCTAssertEqual(unchanged.usage.fiveHour?.utilization, 80)
        let usageRequests = await history.requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertEqual(usageRequests.map(Self.token), ["A", "B"])
    }

    func testLateProfileFromPreviousTokenCannotRestoreOldIdentityOrMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let gate = ContextGate()
        let started = expectation(description: "profile A started")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            if token == "A" { started.fulfill(); await gate.wait() }
            return Self.response(request, body: Self.profile(token))
        }
        _ = await service.fetchUsageHealthSnapshot()
        let old = Task { await service.refreshClaudeCodeAccountProfile() }
        await fulfillment(of: [started], timeout: 2)

        await reader.setToken("B")
        _ = await service.fetchUsageHealthSnapshot()
        await service.refreshClaudeCodeAccountProfile()
        await gate.release()
        await old.value

        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "B@example.com")
        let metadata = await service.fetchCachedClaudeCodeProfileMetadata()
        XCTAssertEqual(metadata?.organizationUUID, "org-B")
    }

    func testLateUsageFailureFromPreviousTokenDoesNotPoisonCurrentHealth() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let gate = ContextGate()
        let started = expectation(description: "usage A started")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            if request.url!.path.hasSuffix("profile") { return Self.response(request, body: Self.profile(token)) }
            if token == "A" {
                started.fulfill()
                await gate.wait()
                return Self.response(request, status: 429, body: "{}")
            }
            return Self.response(request, body: Self.usage(80))
        }
        let old = Task { try await service.fetchUsageOutcome() }
        await fulfillment(of: [started], timeout: 2)
        await reader.setToken("B")
        let current = try await service.fetchUsageOutcome()
        XCTAssertEqual(current.usage.fiveHour?.utilization, 80)
        await gate.release()
        await assertCancelled(old)

        let snapshot = await service.fetchUsageHealthSnapshot()
        XCTAssertEqual(snapshot.oauth.totalFailures, 0)
        XCTAssertEqual(snapshot.runtime.oauthValidationState, .verified)
    }

    func testOwnerRefreshTokenRotationReturnsQuotaFromTheNewToken() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A", refreshedToken: "B")
        let history = ContextRequestHistory()
        let service = fixture.service(reader: reader) { request in
            await history.append(request)
            let token = Self.token(request)
            if request.url!.path.hasSuffix("profile") { return Self.response(request, body: Self.profile("A")) }
            return Self.response(request, status: token == "A" ? 401 : 200, body: Self.usage(80))
        }

        let result = try await service.fetchUsageOutcome()
        XCTAssertEqual(result.usage.fiveHour?.utilization, 80)
        let requests = await history.requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertEqual(requests.map(Self.token), ["A", "B"])
    }

    func testManualInventoryUsesTokenBoundaryEvenWhenReaderChangeFlagIsFalse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            return Self.response(
                request,
                body: request.url!.path.hasSuffix("profile")
                    ? Self.profile(token) : Self.usage(token == "A" ? 10 : 80))
        }
        _ = try await service.fetchUsageOutcome()
        await service.refreshClaudeCodeAccountProfile()
        await reader.setToken("B")

        _ = await service.fetchUsageHealthSnapshot(refreshOAuthCredentialInventory: true)
        let result = try await service.fetchUsageOutcome()
        XCTAssertEqual(result.usage.fiveHour?.utilization, 80)
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "B@example.com")
    }

    func testAnOlderCredentialReadCannotRollBackAnObservedNewToken() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ContextGate()
        let started = expectation(description: "credential A started")
        let reader = ContextOAuthReader(
            token: "A",
            firstRead: {
                started.fulfill(); await gate.wait()
            })
        let history = ContextRequestHistory()
        let service = fixture.service(reader: reader) { request in
            await history.append(request)
            return Self.response(
                request,
                body: request.url!.path.hasSuffix("profile")
                    ? Self.profile(Self.token(request)) : Self.usage(80))
        }
        let old = Task { try await service.fetchUsageOutcome() }
        await fulfillment(of: [started], timeout: 2)
        await reader.setToken("B")
        let current = try await service.fetchUsageOutcome()
        XCTAssertEqual(current.usage.fiveHour?.utilization, 80)
        await gate.release()
        await assertCancelled(old)
        let cached = try await service.fetchUsageOutcome()
        XCTAssertEqual(cached.usage.fiveHour?.utilization, 80)
        let requests = await history.requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertEqual(requests.map(Self.token), ["B"])
    }

    func testLateAutomaticOrganizationSelectionCannotOverrideUserSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ContextGate()
        let started = expectation(description: "automatic organization A probe")
        let history = ContextRequestHistory()
        let service = ClaudeAPIService(
            sessionKey: "fake-session",
            cacheStorage: .init(defaults: fixture.defaults, profileMetadataDirectory: fixture.directory)
        ) { request in
            await history.append(request)
            let path = request.url!.path
            if path.hasSuffix("organizations") { return Self.response(request, body: Self.organizations) }
            if path.contains("/A/") && path.hasSuffix("overage_spend_limit") {
                started.fulfill()
                await gate.wait()
                return Self.response(request, body: Self.overage)
            }
            if path.hasSuffix("overage_spend_limit") { return Self.response(request, body: "null") }
            return Self.response(request, body: Self.usage(path.contains("/B/") ? 80 : 10))
        }
        let old = Task { try await service.validateCurrentSessionUsage() }
        await fulfillment(of: [started], timeout: 2)
        await service.updatePreferredOrganizationID("B")
        await gate.release()
        await assertCancelledUsage(old)

        let current = try await service.validateCurrentSessionUsage()
        XCTAssertEqual(current.fiveHour?.utilization, 80)
        let selected = await service.resolvedSessionOrganizationForLastValidation()
        XCTAssertEqual(selected?.id, "B")
        let usageRequests = await history.requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertTrue(usageRequests.allSatisfy { $0.url!.path.contains("/B/") })
    }

    func testLateUsageAndOverageResponsesAreRejectedAfterOrganizationChange() async throws {
        for overage in [false, true] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let gate = ContextGate()
            let started = expectation(description: overage ? "overage A" : "usage A")
            let service = ClaudeAPIService(
                sessionKey: "fake-session",
                cacheStorage: .init(defaults: fixture.defaults, profileMetadataDirectory: fixture.directory)
            ) { request in
                let path = request.url!.path
                if path.hasSuffix("organizations") { return Self.response(request, body: Self.organizations) }
                if path.contains("/A/"), path.hasSuffix(overage ? "overage_spend_limit" : "usage") {
                    started.fulfill()
                    await gate.wait()
                }
                return Self.response(
                    request, body: path.hasSuffix("overage_spend_limit") ? Self.overage : Self.usage(80))
            }
            await service.updatePreferredOrganizationID("A")
            let old = Task {
                if overage {
                    _ = try await service.fetchOverageSpendLimit()
                } else {
                    _ = try await service.validateCurrentSessionUsage()
                }
            }
            await fulfillment(of: [started], timeout: 2)
            await service.updatePreferredOrganizationID("B")
            await gate.release()
            do { try await old.value; XCTFail("previous organization response must stop") } catch is CancellationError {
            } catch { XCTFail("expected cancellation: \(error)") }
        }
    }

    func testLateSameContextAutomaticSelectionKeepsPrimaryAndSupplementalInSameOrganization() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = fixture.store.upsertWebSessionAccount(sessionKey: "fake-session")
        let oldSelectionGate = ContextGate()
        let primaryGate = ContextGate()
        let oldSelectionStarted = expectation(description: "old automatic selection started")
        let primaryStarted = expectation(description: "new primary quota for A started")
        let history = ContextRequestHistory()
        let service = ClaudeAPIService(
            accountStore: fixture.store, oauthCredentialReader: ContextOAuthReader(token: "unused"),
            sessionKeyLoader: { _ in "fake-session" },
            cacheStorage: .init(defaults: fixture.defaults, profileMetadataDirectory: fixture.directory)
        ) { request in
            await history.append(request)
            let path = request.url!.path
            let requestNumber = await history.count(path: path)
            if path.hasSuffix("organizations") { return Self.response(request, body: Self.organizations) }
            if path.contains("/A/"), path.hasSuffix("overage_spend_limit") {
                if requestNumber == 1 {
                    oldSelectionStarted.fulfill()
                    await oldSelectionGate.wait()
                    return Self.response(request, body: "null")
                }
                return Self.response(request, body: Self.spendLimit(limit: 1000, used: 100))
            }
            if path.contains("/B/"), path.hasSuffix("overage_spend_limit") {
                return Self.response(
                    request, body: requestNumber == 1 ? "null" : Self.spendLimit(limit: 2000, used: 1400))
            }
            if path.contains("/A/"), path.hasSuffix("usage"), requestNumber == 1 {
                primaryStarted.fulfill()
                await primaryGate.wait()
            }
            return Self.response(request, body: Self.usage(path.contains("/B/") ? 80 : 10))
        }
        let old = Task { try await service.fetchUsageOutcome() }
        await fulfillment(of: [oldSelectionStarted], timeout: 2)
        let current = Task {
            try await ClaudeRuntimeRefresher.refresh(
                apiService: service, lastOverageAttemptAt: nil,
                knownIdentities: [account.id: .init(accountID: "user", organizationID: "A")])
        }
        await fulfillment(of: [primaryStarted], timeout: 2)
        await oldSelectionGate.release()
        let oldResult = try await old.value
        XCTAssertEqual(oldResult.identity?.organizationID, "A", "Late automatic selection reuses the established scope")
        await primaryGate.release()
        let result = try await current.value
        XCTAssertEqual(result.usage.fiveHour?.utilization, 10)
        XCTAssertEqual(result.metadata.account?.identity.mergeKey, "user|A")
        if case .success(let overage, _) = result.supplementalUsage {
            XCTAssertEqual(overage.monthlyCreditLimitCents, 1000)
            XCTAssertEqual(overage.usedCreditsCents, 100)
        } else {
            XCTFail("supplemental money must come from primary organization A")
        }
        let requests = await history.requests
        let quotaRequests = requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertEqual(quotaRequests.count, 2)
        XCTAssertTrue(quotaRequests.allSatisfy { $0.url!.path.contains("/A/") })
        XCTAssertTrue(requests.last?.url?.path.contains("/A/overage_spend_limit") == true)
    }

    func testScopedOverageRejectsContextChangeBeforeStartingRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = ContextRequestHistory()
        let service = ClaudeAPIService(
            sessionKey: "fake-session",
            cacheStorage: .init(defaults: fixture.defaults, profileMetadataDirectory: fixture.directory)
        ) { request in
            await history.append(request)
            return Self.response(
                request, body: request.url!.path.hasSuffix("organizations") ? Self.organizations : Self.usage(10))
        }
        await service.updatePreferredOrganizationID("A")
        let revision = await service.currentSessionContextRevision()
        let primary = try await service.fetchUsageOutcome()
        XCTAssertEqual(primary.identity?.organizationID, "A")
        await service.updatePreferredOrganizationID("B")
        do {
            _ = try await service.fetchOverageSpendLimit(
                organizationID: primary.identity?.organizationID, expectedSessionContextRevision: revision)
            XCTFail("a primary scope from the previous context must not start a money request")
        } catch is CancellationError {
        } catch {
            XCTFail("expected cancellation: \(error)")
        }
        let requests = await history.requests
        XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("overage_spend_limit") })
    }

    func testScopedOverageUsesGivenOrganizationInsteadOfCachedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let history = ContextRequestHistory()
        let service = ClaudeAPIService(
            sessionKey: "fake-session",
            cacheStorage: .init(defaults: fixture.defaults, profileMetadataDirectory: fixture.directory)
        ) { request in
            await history.append(request)
            let path = request.url!.path
            if path.hasSuffix("organizations") { return Self.response(request, body: Self.organizations) }
            if path.hasSuffix("overage_spend_limit") {
                return Self.response(
                    request, body: Self.spendLimit(limit: path.contains("/A/") ? 1000 : 2000, used: 100))
            }
            return Self.response(request, body: Self.usage(10))
        }
        await service.updatePreferredOrganizationID("B")
        _ = try await service.validateCurrentSessionUsage()
        let revision = await service.currentSessionContextRevision()
        let overage = try await service.fetchOverageSpendLimit(
            organizationID: "A", expectedSessionContextRevision: revision)
        XCTAssertEqual(overage.monthlyCreditLimitCents, 1000)
        let requests = await history.requests
        XCTAssertTrue(requests.last?.url?.path.contains("/A/overage_spend_limit") == true)
    }

    func testSameAccountRotationKeepsVerifiedProfileWhileCheckingNewCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let gate = ContextGate()
        let started = expectation(description: "new token profile verification")
        let service = fixture.service(reader: reader) { request in
            if request.url!.path.hasSuffix("profile") {
                if Self.token(request) == "B" { started.fulfill(); await gate.wait() }
                return Self.response(request, body: Self.profile("A"))
            }
            return Self.response(request, body: Self.usage(Self.token(request) == "A" ? 10 : 20))
        }
        _ = try await service.fetchUsageOutcome()
        await reader.setToken("B")
        let changed = Task { try await service.fetchUsageOutcome() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "A@example.com")
        let whileChecking = await service.fetchCachedClaudeCodeProfileMetadata()
        XCTAssertEqual(whileChecking?.organizationUUID, "org-A")
        await gate.release()
        let result = try await changed.value
        XCTAssertEqual(result.usage.fiveHour?.utilization, 20)
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "A@example.com")
    }

    func testVerifiedUUIDAndOrganizationPublishWithoutDisplayEmail() async throws {
        for email: String? in [nil, "", "   "] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let reader = ContextOAuthReader(token: "B")
            let service = fixture.service(reader: reader) { request in
                Self.response(
                    request,
                    body: request.url!.path.hasSuffix("profile")
                        ? Self.profile(accountUUID: "B", organizationID: "org-B", email: email) : Self.usage(80))
            }
            let result = try await service.fetchUsageOutcome()
            let owner = try XCTUnwrap(result.identity)
            XCTAssertEqual(owner.mergeKey, "B|org-B")
            XCTAssertNil(owner.email)
            XCTAssertEqual(result.usage.fiveHour?.utilization, 80)
            XCTAssertNil(fixture.store.activeAccount()?.identity.email)
            XCTAssertEqual(fixture.store.activeAccount()?.identity.organizationID, "org-B")
            let metadata = await service.fetchCachedClaudeCodeProfileMetadata()
            XCTAssertEqual(metadata?.organizationUUID, "org-B")
        }
    }

    func testDifferentVerifiedUserInSameOrganizationDoesNotKeepOldDisplayEmail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            return Self.response(
                request,
                body: request.url!.path.hasSuffix("profile")
                    ? Self.profile(
                        accountUUID: token, organizationID: "org-A", email: token == "A" ? "A@example.com" : nil)
                    : Self.usage(token == "A" ? 10 : 80))
        }
        let initial = try await service.fetchUsageOutcome()
        XCTAssertEqual(initial.identity?.mergeKey, "A|org-A")
        await reader.setToken("B")
        let changed = try await service.fetchUsageOutcome()
        XCTAssertEqual(changed.identity?.mergeKey, "B|org-A")
        XCTAssertNil(changed.identity?.email)
        XCTAssertNil(fixture.store.activeAccount()?.identity.email)
        XCTAssertEqual(fixture.store.activeAccount()?.identity.organizationID, "org-A")
    }

    func testSameVerifiedOwnerRotationWithoutEmailKeepsLabelButCannotPublishWhilePending() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let gate = ContextGate()
        let started = expectation(description: "same owner profile without email started")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            if request.url!.path.hasSuffix("profile") {
                if token == "B" { started.fulfill(); await gate.wait() }
                return Self.response(
                    request,
                    body: Self.profile(
                        accountUUID: "A", organizationID: "org-A", email: token == "A" ? "A@example.com" : nil))
            }
            return Self.response(request, body: Self.usage(token == "A" ? 89 : 96))
        }
        let initial = try await service.fetchUsageOutcome()
        await reader.setToken("B")
        let rotated = Task { try await service.fetchUsageOutcome() }
        await fulfillment(of: [started], timeout: 2)
        let pendingOwner = await service.currentRuntimeUsageAccountIdentity()
        XCTAssertNil(pendingOwner, "A prior generation is comparison evidence, not the pending credential's owner")
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "A@example.com")
        await gate.release()
        let changed = try await rotated.value
        XCTAssertEqual(changed.identity?.mergeKey, initial.identity?.mergeKey)
        XCTAssertEqual(changed.identity?.email, "A@example.com")
        XCTAssertEqual(fixture.store.activeAccount()?.identity.email, "A@example.com")
        let metadata = await service.fetchCachedClaudeCodeProfileMetadata()
        XCTAssertEqual(metadata?.organizationUUID, "org-A")
    }

    func testIncompleteCanonicalIdentityKeepsNumericUsageWithoutPublishingPreviousOwner() async throws {
        let incomplete: [(String?, String?, String?)] = [
            (nil, "org-A", "A@example.com"), ("A", nil, "A@example.com"), ("   ", "org-A", nil),
        ]
        for (accountUUID, organizationID, email) in incomplete {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let reader = ContextOAuthReader(token: "A")
            let service = fixture.service(reader: reader) { request in
                let token = Self.token(request)
                return Self.response(
                    request,
                    body: request.url!.path.hasSuffix("profile")
                        ? (token == "A"
                            ? Self.profile("A")
                            : Self.profile(accountUUID: accountUUID, organizationID: organizationID, email: email))
                        : Self.usage(token == "A" ? 10 : 80))
            }
            _ = try await service.fetchUsageOutcome()
            await reader.setToken("B")
            let changed = try await service.fetchUsageOutcome()
            XCTAssertEqual(changed.usage.fiveHour?.utilization, 80)
            XCTAssertNil(changed.identity)
            let runtimeOwner = await service.currentRuntimeUsageAccountIdentity()
            XCTAssertNil(runtimeOwner)
        }
    }

    func testUnknownNewIdentityDoesNotInheritPreviousIdentityButKeepsNumericUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let service = fixture.service(reader: reader) { request in
            let token = Self.token(request)
            if request.url!.path.hasSuffix("profile") {
                return Self.response(request, status: token == "B" ? 503 : 200, body: Self.profile(token))
            }
            return Self.response(request, body: Self.usage(token == "A" ? 10 : 80))
        }
        _ = try await service.fetchUsageOutcome()
        await reader.setToken("B")
        let result = try await service.fetchUsageOutcome()
        XCTAssertEqual(result.usage.fiveHour?.utilization, 80)
        XCTAssertNil(fixture.store.activeAccount()?.identity.email)
        XCTAssertNil(fixture.store.activeAccount()?.identity.organizationID)
        let metadata = await service.fetchCachedClaudeCodeProfileMetadata()
        XCTAssertNil(metadata)
    }

    func testContextCancellationDoesNotRetryWithAnotherCredential() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reader = ContextOAuthReader(token: "A")
        let gate = ContextGate()
        let started = expectation(description: "usage A started")
        let history = ContextRequestHistory()
        let service = fixture.service(reader: reader) { request in
            await history.append(request)
            if request.url!.path.hasSuffix("profile") {
                return Self.response(request, body: Self.profile(Self.token(request)))
            }
            started.fulfill()
            await gate.wait()
            return Self.response(request, body: Self.usage(10))
        }
        let old = Task { try await service.fetchUsageWithRetryOutcome(maxAttempts: 3) }
        await fulfillment(of: [started], timeout: 2)
        await reader.setToken("B")
        _ = await service.fetchUsageHealthSnapshot()
        await gate.release()
        await assertCancelled(old)
        let requests = await history.requests.filter { $0.url!.path.hasSuffix("usage") }
        XCTAssertEqual(requests.map(Self.token), ["A"])
    }

    func testProbeKeepsOwnerAuthenticationAndDisablesUserCustomizations() {
        XCTAssertEqual(
            ClaudeCodeCLI.refreshArguments,
            [
                "-p", "/usage", "--safe-mode", "--strict-mcp-config", "--no-session-persistence",
            ])
        XCTAssertFalse(ClaudeCodeCLI.refreshArguments.contains("--bare"))
    }

    private func assertCancelled(_ task: Task<ClaudeUsageFetchOutcome, Error>) async {
        do { _ = try await task.value; XCTFail("old credential result must stop") } catch is CancellationError {} catch
        { XCTFail("expected cancellation: \(error)") }
    }

    private func assertCancelledUsage(_ task: Task<ClaudeUsageResponse, Error>) async {
        do { _ = try await task.value; XCTFail("old organization result must stop") } catch is CancellationError {
        } catch { XCTFail("expected cancellation: \(error)") }
    }

    nonisolated private static func token(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "Authorization")!.replacingOccurrences(of: "Bearer ", with: "")
    }

    nonisolated private static func response(_ request: URLRequest, status: Int = 200, body: String) -> (
        Data, URLResponse
    ) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated private static func profile(_ token: String) -> String {
        """
        {"account":{"uuid":"\(token)","email":"\(token)@example.com"},
         "organization":{"uuid":"org-\(token)","name":"\(token)","organization_type":"team"}}
        """
    }

    nonisolated private static func profile(accountUUID: String?, organizationID: String?, email: String?) -> String {
        var account: [String: String] = [:]
        if let accountUUID { account["uuid"] = accountUUID }
        if let email { account["email"] = email }
        var organization = ["name": "Organization", "organization_type": "team"]
        if let organizationID { organization["uuid"] = organizationID }
        return String(
            data: try! JSONSerialization.data(withJSONObject: ["account": account, "organization": organization]),
            encoding: .utf8)!
    }

    nonisolated private static func usage(_ value: Int) -> String {
        "{\"five_hour\":{\"utilization\":\(value),\"resets_at\":null}}"
    }

    nonisolated private static var organizations: String {
        #"[{"uuid":"A","name":"A"},{"uuid":"B","name":"B"}]"#
    }

    nonisolated private static func spendLimit(limit: Int, used: Int) -> String {
        "{\"monthly_credit_limit\":\(limit),\"used_credits\":\(used),\"is_enabled\":true,\"out_of_credits\":false,\"currency\":\"USD\"}"
    }

    nonisolated private static var overage: String {
        #"{"monthly_credit_limit":1000,"used_credits":100,"is_enabled":true,"out_of_credits":false,"currency":"USD"}"#
    }

    private struct Fixture {
        let suite = "ClaudeCredentialContextTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: ClaudeAccountStore
        let directory: URL

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            store = ClaudeAccountStore(
                defaults: defaults, keychainVault: ContextEmptyVault(), postsNotifications: false)
            _ = store.upsertClaudeCodeExternalAccount(
                identity: .init(email: "A@example.com", organizationID: "org-A"),
                validationState: .verified, setActiveIfMissing: true)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func service(reader: ContextOAuthReader, http: @escaping ClaudeAPIService.HTTPRunner) -> ClaudeAPIService {
            ClaudeAPIService(
                accountStore: store, oauthCredentialReader: reader, sessionKeyLoader: { _ in nil },
                cacheStorage: .init(defaults: defaults, profileMetadataDirectory: directory), httpRunner: http)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private actor ContextOAuthReader: ClaudeOAuthCredentialReading {
    private var token: String
    private let refreshedToken: String?
    private var firstRead: (@Sendable () async -> Void)?

    init(token: String, refreshedToken: String? = nil, firstRead: (@Sendable () async -> Void)? = nil) {
        self.token = token
        self.refreshedToken = refreshedToken
        self.firstRead = firstRead
    }

    func setToken(_ value: String) { token = value }
    func readAccessToken() async throws -> String? {
        let captured = token
        if let block = firstRead { firstRead = nil; await block() }
        return captured
    }
    func refreshCredentialInventoryWithoutUI() -> ClaudeOAuthCredentialInventoryRefresh {
        .init(accessToken: token, credentialChanged: false)
    }
    func forceRefreshAccessToken() -> String? {
        if let refreshedToken { token = refreshedToken }
        return token
    }
    func invalidateCache() {}
    func importActiveCLICredential() -> ClaudeOAuthCredentialImportResult { .available }
}

private actor ContextGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor ContextRequestHistory {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    func count(path: String) -> Int { requests.filter { $0.url?.path == path }.count }
}

private nonisolated struct ContextEmptyVault: ClaudeSessionKeyVault {
    func saveString(_ value: String, account: String) throws {}
    func loadString(account: String) throws -> String? { nil }
    func delete(account: String) throws {}
}
