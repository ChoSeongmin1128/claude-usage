import Foundation
import XCTest

@testable import ClaudeUsage

final class AntigravityLiveAGYIntegrationTests: XCTestCase {
    func testProductionLauncherPublishesHTTPSPortToPTY()
        async throws
    {
        guard ProcessInfo.processInfo.environment[
            "CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"
        ] == "1" else {
            throw XCTSkip(
                "CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=1 is required"
            )
        }

        let home = FileManager.default.realHomeDirectory
        let resolution =
            AntigravityProductionExecutableCatalogResolver(
                homeDirectoryURL: home
            ).resolve()
        let executable = try XCTUnwrap(
            resolution.managedLaunchExecutable,
            "A verified official AGY CLI is required"
        )
        let request = try XCTUnwrap(
            AntigravityManagedCLIProcessLaunchRequest(
                executable: executable,
                environment: AntigravityManagedCLIEnvironment(
                    homeDirectory: home
                ),
                currentDirectoryURL: home
            )
        )
        let handle = try AntigravityManagedCLIProcessLauncher()
            .launchSuspended(request)

        do {
            try handle.resume()
            var classifier =
                AntigravityManagedCLIOutputClassifier()
            let deadline = ContinuousClock.now.advanced(
                by: .seconds(10)
            )
            while ContinuousClock.now < deadline,
                  classifier.announcedLocalServerPort == nil
            {
                _ = classifier.ingest(
                    handle.drainOutput(
                        maximumBytes: 4 * 1_024
                    )
                )
                try await Task.sleep(
                    for: .milliseconds(100)
                )
            }

            let announcedPort =
                classifier.announcedLocalServerPort
            let termination = await handle.terminateTree(
                gracePeriod: .milliseconds(250)
            )
            XCTAssertEqual(termination, .confirmed)
            XCTAssertNotNil(
                announcedPort,
                "Expected AGY's supported HTTPS bootstrap announcement on the managed PTY"
            )
        } catch {
            _ = await handle.terminateTree(
                gracePeriod: .milliseconds(250)
            )
            throw error
        }
    }

    func testProductionManagedPathReturnsRealGroupedQuota()
        async throws
    {
        guard ProcessInfo.processInfo.environment[
            "CLAUDEUSAGE_RUN_LIVE_AGY_TESTS"
        ] == "1" else {
            throw XCTSkip(
                "CLAUDEUSAGE_RUN_LIVE_AGY_TESTS=1 is required"
            )
        }

        let home = FileManager.default.realHomeDirectory
        let resolution =
            AntigravityProductionExecutableCatalogResolver(
                homeDirectoryURL: home
            ).resolve()
        let executable = try XCTUnwrap(
            resolution.managedLaunchExecutable,
            "A verified official AGY CLI is required"
        )
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClaudeUsage-live-agy-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stateDirectory.path
        )
        defer {
            try? FileManager.default.removeItem(
                at: stateDirectory
            )
        }

        let composition =
            AntigravityManagedRuntimeCompositionFactory
                .makeProduction(
                catalog: resolution.catalog,
                managedStateDirectoryURL: stateDirectory,
                currentDirectoryURL: home
            )
        let deadline = AntigravityRPCDeadline(
            totalTimeout:
                AntigravityRPCDeadline.defaultRefreshTimeout
        )
        let result: AntigravityLocalQuotaFetchResult
        do {
            result = try await composition.managedSession
                .withRuntime(
                    authorization:
                        .automatic(
                            idleTimeout: .seconds(180)
                        ),
                    executable: executable,
                    deadline: deadline
                ) { runtime in
                    do {
                        return try await
                            composition.localRPCClient.fetch(
                                from: runtime.endpoint,
                                deadline: deadline
                            )
                    } catch {
                        throw LiveAGYIntegrationTestError.rpcFetch(
                            String(reflecting: error)
                        )
                    }
                }
        } catch {
            await composition.managedSession.shutdown()
            if let error =
                error as? LiveAGYIntegrationTestError {
                throw error
            }
            throw LiveAGYIntegrationTestError.managedSession(
                String(reflecting: error)
            )
        }
        guard case .grouped(let snapshot, _) = result
        else {
            await composition.managedSession.shutdown()
            return XCTFail(
                "Expected real grouped quota, got \(result)"
            )
        }
        let quotaDiagnostics = snapshot.lanes.map { lane in
            let remaining = lane.remainingFraction.map {
                String($0)
            }
                ?? "nil"
            return "\(lane.id.rawValue)=\(remaining)"
        }.joined(separator: ",")
        Swift.print(
            "LIVE_AGY_QUOTAS \(quotaDiagnostics)"
        )
        XCTAssertEqual(
            snapshot.provenance.transport,
            .managedAGYRPC
        )
        XCTAssertEqual(
            snapshot.provenance.endpointOwner,
            .managed
        )
        XCTAssertEqual(
            snapshot.provenance.capability,
            .groupedQuotaSummary
        )
        XCTAssertNotNil(snapshot.provenance.processIdentity)
        XCTAssertFalse(
            snapshot.identity?.email?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty ?? true
        )
        XCTAssertFalse(snapshot.lanes.isEmpty)
        XCTAssertTrue(
            snapshot.lanes.contains {
                $0.remainingFraction != nil
            }
        )
        assertStandardFiveHourAndWeeklyQuota(
            in: snapshot
        )
        let presentation =
            AntigravityQuotaPresentationMapper.map(
                snapshot: snapshot,
                settings: .default,
                now: snapshot.fetchedAt,
                timeZone: .current
            )
        for expectedGroup in ["Gemini", "Claude · GPT"] {
            let group = try XCTUnwrap(
                presentation.groups.first {
                    $0.title == expectedGroup
                },
                "Expected \(expectedGroup) in the live AGY presentation"
            )
            XCTAssertEqual(
                group.lanes.map(\.cadenceTitle),
                ["5시간", "주간"]
            )
        }

        guard let identity = snapshot.identity else {
            await composition.managedSession.shutdown()
            return XCTFail(
                "Expected the real AGY account identity"
            )
        }
        let accountID = AntigravityAccountID(uuid: UUID())
        let account = AntigravityStoredAccount(
            id: accountID,
            label: identity.email ?? "Live AGY",
            externalIdentity:
                AntigravityExternalAccountIdentity(
                    googleSubject:
                        identity.stableAccountID,
                    email: identity.email
                ),
            migrationAliases: [],
            lifecycle: .active,
            credentialReference:
                AntigravityCredentialReference(uuid: UUID()),
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1
        )
        let repository = LiveAGYRefreshRepository(
            account: account,
            credentials: AntigravityOAuthCredentials(
                accessToken: "unused-live-test-token",
                refreshToken: "unused-live-test-refresh",
                expiryDate:
                    Date().addingTimeInterval(3_600),
                email: identity.email,
                clientID: "unused-live-test-client"
            )
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                AntigravityDiscoveredLocalUsageSource(
                    id: .localApp,
                    discovery: composition.discovery,
                    client: composition.localRPCClient
                ),
                AntigravityDiscoveredLocalUsageSource(
                    id: .borrowedCLI,
                    discovery: composition.discovery,
                    client: composition.localRPCClient
                ),
                AntigravityManagedCLIUsageSource(
                    session: composition.managedSession,
                    executable: executable,
                    client: composition.localRPCClient
                ),
            ]
        )
        let automatic = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .manual,
                accountTarget: .selectedOAuth(accountID),
                repositoryRevision: 0,
                connection: .default,
                managedLaunch: .enabled
            )
        )
        let automaticSnapshot: AntigravityQuotaSnapshot
        switch automatic {
        case .ready(let value), .partial(let value, _):
            automaticSnapshot = value
        default:
            await composition.managedSession.shutdown()
            return XCTFail(
                "Expected automatic managed quota, got \(automatic)"
            )
        }
        // An already-running, verified AGY is intentionally reused before
        // the managed source. The direct session assertion above proves the
        // managed path; this automatic-plan assertion must honor source
        // precedence instead of assuming a clean machine.
        switch automaticSnapshot.provenance.transport {
        case .borrowedAGYRPC:
            XCTAssertEqual(
                automaticSnapshot.provenance
                    .endpointOwner,
                .borrowed
            )
        case .managedAGYRPC:
            XCTAssertEqual(
                automaticSnapshot.provenance
                    .endpointOwner,
                .managed
            )
        case .localAppRPC, .googleOAuth:
            XCTFail(
                "Expected an AGY RPC source, got \(automaticSnapshot.provenance.transport)"
            )
        }
        XCTAssertTrue(
            AntigravityAccountIdentityMatcher.match(
                expected: identity,
                received: automaticSnapshot.identity
            ).isMatch
        )
        assertStandardFiveHourAndWeeklyQuota(
            in: automaticSnapshot
        )
        await composition.managedSession.shutdown()
    }

    private func assertStandardFiveHourAndWeeklyQuota(
        in snapshot: AntigravityQuotaSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for scope in [
            AntigravityQuotaScope.gemini,
            .thirdPartyModels,
        ] {
            let cadences = Set(
                snapshot.lanes
                    .filter { $0.scope == scope }
                    .map(\.cadence)
            )
            XCTAssertTrue(
                cadences.contains(.fiveHour),
                "Expected a live 5-hour quota for \(scope)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                cadences.contains(.weekly),
                "Expected a live weekly quota for \(scope)",
                file: file,
                line: line
            )
        }
    }
}

private enum LiveAGYIntegrationTestError: Error {
    case managedSession(String)
    case rpcFetch(String)
}

private enum LiveAGYRefreshRepositoryError: Error {
    case unexpectedCredentialMutation
}

private actor LiveAGYRefreshRepository:
    AntigravityRefreshAccountRepository
{
    private let storedState:
        AntigravityAccountRepositoryState
    private let storedSnapshot:
        AntigravityCredentialSnapshot

    init(
        account: AntigravityStoredAccount,
        credentials: AntigravityOAuthCredentials
    ) {
        storedState = AntigravityAccountRepositoryState(
            revision: 0,
            activeAccountID: account.id,
            accounts: [account]
        )
        storedSnapshot = AntigravityCredentialSnapshot(
            repositoryRevision: 0,
            account: account,
            credentials: credentials
        )
    }

    func state() async throws
        -> AntigravityAccountRepositoryState
    {
        storedState
    }

    func credentialSnapshot(
        for accountID: AntigravityAccountID
    ) async throws -> AntigravityCredentialSnapshot? {
        storedSnapshot.account.id == accountID
            ? storedSnapshot
            : nil
    }

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity:
            AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        _ = accountID
        _ = credentials
        _ = externalIdentity
        _ = expectedRevision
        throw LiveAGYRefreshRepositoryError
            .unexpectedCredentialMutation
    }
}
