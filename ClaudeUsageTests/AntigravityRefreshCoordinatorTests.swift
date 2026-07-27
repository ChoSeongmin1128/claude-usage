import XCTest
@testable import ClaudeUsage

final class AntigravityRefreshCoordinatorTests: XCTestCase {
    func testGooglePolicyWithoutSelectedAccountReturnsSetupRequired() async {
        let repository = RefreshRepositoryDouble(
            accounts: [],
            activeAccountID: nil,
            credentials: [:]
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: []
        )

        let result = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .sourceBoundaryChanged,
                accountTarget: .ambientLocal,
                repositoryRevision: 0,
                connection: makeConnectionSettings(
                    policy: .googleAccount
                )
            )
        )

        XCTAssertEqual(
            result,
            .setupRequired(.noSelectedOAuthAccount)
        )
    }

    func testUnavailableAmbientSourcesReturnLocalSessionSetup() async {
        let repository = RefreshRepositoryDouble(
            accounts: [],
            activeAccountID: nil,
            credentials: [:]
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .failure(.unavailable),
                    ])
                ),
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .failure(.unavailable),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .manual,
                accountTarget: .ambientLocal,
                repositoryRevision: 0,
                connection: makeConnectionSettings(
                    policy: .localSession
                )
            )
        )

        XCTAssertEqual(
            result,
            .setupRequired(.noAmbientLocalSession)
        )
    }

    func testConnectionSnapshotControlsManagedTimeoutAndSingleFlightIdentity() async {
        let identity = ProviderAccountIdentity(
            stableAccountID: "local-subject",
            email: "local@example.com"
        )
        let snapshot = makeSnapshot(
            identity: identity,
            source: .managedCLI
        )
        let sourceScript =
            ConnectionSnapshotRefreshSourceScript(
                response: .init(payload: .grouped(snapshot))
            )
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(
                accounts: [],
                activeAccountID: nil,
                credentials: [:]
            ),
            sources: [
                ConnectionSnapshotRefreshSource(
                    script: sourceScript
                ),
            ]
        )
        let firstCompletion = expectation(
            description: "superseded connection snapshot"
        )
        let firstResultBox = RefreshPresentationResultBox()
        let firstRequest = AntigravityRefreshRequest(
            trigger: .manual,
            accountTarget: .ambientLocal,
            repositoryRevision: 0,
            connection: makeConnectionSettings(
                policy: .localSession,
                allowManagedCLI: true,
                managedIdleTimeoutSeconds: 31
            )
        )
        let secondRequest = AntigravityRefreshRequest(
            trigger: .manual,
            accountTarget: .ambientLocal,
            repositoryRevision: 0,
            connection: makeConnectionSettings(
                policy: .localSession,
                allowManagedCLI: true,
                managedIdleTimeoutSeconds: 47
            )
        )

        let first = Task {
            let result = await coordinator.refresh(firstRequest)
            await firstResultBox.store(result)
            firstCompletion.fulfill()
            return result
        }
        await sourceScript.waitUntilFirstStarted()

        let second = await coordinator.refresh(secondRequest)
        await fulfillment(of: [firstCompletion], timeout: 1)
        let firstResult = await firstResultBox.value()
        let idleTimeouts = await sourceScript.idleTimeouts()
        XCTAssertEqual(firstResult, .failed(.cancelled))
        XCTAssertEqual(second, .ready(snapshot))
        XCTAssertEqual(
            idleTimeouts,
            [.seconds(31), .seconds(47)]
        )

        await sourceScript.resumeFirst()
        let completedFirst = await first.value
        XCTAssertEqual(completedFirst, .failed(.cancelled))
    }

    func testOAuthAuthenticationFailureRemainsTyped() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .failure(.authenticationRequired),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )
        XCTAssertEqual(
            result,
            .failed(.authenticationRequired(.googleOAuth))
        )
    }

    func testSourceFailuresPreserveDeadlineSchemaTransportAndInteractionTypes() async {
        let cases: [
            (
                AntigravityUsageSourceError,
                AntigravityFailure
            )
        ] = [
            (
                .deadlineExceeded,
                .deadlineExceeded(.googleOAuth)
            ),
            (
                .malformedResponse,
                .schemaChanged(.googleOAuth)
            ),
            (
                .transportFailure,
                .transportUnavailable(.googleOAuth)
            ),
            (
                .interactionRequired,
                .interactionRequired(.googleOAuth)
            ),
        ]

        for (sourceError, expectedFailure) in cases {
            let account = makeAccount(
                id: "account-a",
                subject: "subject-a",
                email: "a@example.com"
            )
            let repository = RefreshRepositoryDouble(
                accounts: [account],
                activeAccountID: account.id,
                credentials: [
                    account.id: makeCredentials("a"),
                ]
            )
            let coordinator = AntigravityRefreshCoordinator(
                repository: repository,
                sources: [
                    ScriptedRefreshSource(
                        id: .googleOAuth,
                        script: RefreshSourceScript(outcomes: [
                            .failure(sourceError),
                        ])
                    ),
                ]
            )

            let result = await coordinator.refresh(
                selectedRequest(
                    accountID: account.id,
                    revision: 0,
                    policy: .googleAccount
                )
            )
            XCTAssertEqual(
                result,
                .failed(expectedFailure)
            )
        }
    }

    func testSelectedAccountRejectsMismatchedLocalAndKeepsOAuthProvenance() async throws {
        let accountA = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [accountA],
            activeAccountID: accountA.id,
            credentials: [
                accountA.id: makeCredentials("a"),
            ]
        )
        let localScript = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(
                makeSnapshot(
                    identity: .init(
                        stableAccountID: "subject-b",
                        email: "b@example.com"
                    ),
                    source: .localApp
                )
            ))),
        ])
        let oauthSnapshot = makeSnapshot(
            identity: accountA.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let oauthScript = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(oauthSnapshot))),
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: localScript
                ),
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: oauthScript
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: accountA.id,
                revision: 0,
                policy: .automatic
            )
        )

        XCTAssertEqual(result, .ready(oauthSnapshot))
        let localCallCount = await localScript.callCount()
        let oauthCallCount = await oauthScript.callCount()
        let localAuthorizationFlags =
            await localScript.authorizationFlags()
        let oauthAuthorizationFlags =
            await oauthScript.authorizationFlags()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(oauthCallCount, 1)
        XCTAssertEqual(localAuthorizationFlags, [false])
        XCTAssertEqual(oauthAuthorizationFlags, [true])
    }

    func testSelectedAccountRejectsIdentitylessLocalBeforeOAuthFallback() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let identityless = makeSnapshot(
            identity: nil,
            source: .localApp
        )
        let oauth = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(identityless)
                        )),
                    ])
                ),
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(oauth)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .automatic
            )
        )
        XCTAssertEqual(result, .ready(oauth))
    }

    func testIdentityOnlyResultPreservesPlanProvenanceAndTimestamp() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let observation = makeIdentityOnlyUsage(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .identityOnly(observation)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )

        XCTAssertEqual(result, .identityOnly(observation))
    }

    func testLimitedOAuthEvidenceOutranksEarlierIdentityOnlyCandidate() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let identity = account.externalIdentity
            .providerAccountIdentity
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let identityOnly = makeIdentityOnlyUsage(
            identity: identity,
            source: .localApp
        )
        let limited =
            makeGoogleOAuthLimitedCapability(
                identity: identity
            )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .identityOnly(identityOnly)
                        )),
                    ])
                ),
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .limited(limited)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .automatic
            )
        )

        XCTAssertEqual(result, .limited(limited))
    }

    func testOAuthCredentialMutationCommitsWhenEarlierLocalLimitedPayloadWins() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let identity = account.externalIdentity
            .providerAccountIdentity
        let localLimited =
            makeLocalLimitedCapability(identity: identity)
        let oauthPayloads: [AntigravityUsageSourcePayload] = [
            .limited(
                makeGoogleOAuthLimitedCapability(
                    identity: identity
                )
            ),
            .identityOnly(
                makeIdentityOnlyUsage(
                    identity: identity,
                    source: .googleOAuth
                )
            ),
        ]

        for (index, oauthPayload) in
            oauthPayloads.enumerated()
        {
            let original = makeCredentials("old-\(index)")
            let refreshed = makeCredentials("new-\(index)")
            let repository = RefreshRepositoryDouble(
                accounts: [account],
                activeAccountID: account.id,
                credentials: [account.id: original]
            )
            let coordinator = AntigravityRefreshCoordinator(
                repository: repository,
                sources: [
                    ScriptedRefreshSource(
                        id: .localApp,
                        script: RefreshSourceScript(outcomes: [
                            .success(.init(
                                payload:
                                    .limited(localLimited)
                            )),
                        ])
                    ),
                    ScriptedRefreshSource(
                        id: .googleOAuth,
                        script: RefreshSourceScript(outcomes: [
                            .success(.init(
                                payload: oauthPayload,
                                refreshedCredential: refreshed
                            )),
                        ])
                    ),
                ]
            )

            let result = await coordinator.refresh(
                selectedRequest(
                    accountID: account.id,
                    revision: 0,
                    policy: .automatic
                )
            )

            XCTAssertEqual(result, .limited(localLimited))
            let stored = await repository.credentialsValue(
                for: account.id
            )
            let state = await repository.stateValue()
            let replaceCount =
                await repository.replaceCountValue()
            XCTAssertEqual(stored, refreshed)
            XCTAssertEqual(state.revision, 1)
            XCTAssertEqual(replaceCount, 1)
        }
    }

    func testCoordinatorRejectsOAuthLimitedPayloadWithLocalEvidence() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let identity = account.externalIdentity
            .providerAccountIdentity
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let invalid =
            AntigravityLimitedQuotaCapability.localLegacy(
                evidence:
                    AntigravityLegacyCapabilityEvidence(
                        method: .getUserStatus,
                        identity: identity,
                        plan: "Pro",
                        modelConfigCount: 1
                    ),
                fallbackReason:
                    .groupedQuotaUnavailable,
                provenance: makeProvenance(
                    identity: identity,
                    source: .googleOAuth,
                    capability: .limitedQuota
                ),
                fetchedAt: Date(
                    timeIntervalSince1970: 1_900_000_002
                )
            )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .limited(invalid)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )

        XCTAssertEqual(
            result,
            .failed(
                .sourceContractViolation(.googleOAuth)
            )
        )
    }

    func testAmbientLocalUsesObservedIdentityWithoutChangingActiveOAuthAccount() async throws {
        let accountA = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [accountA],
            activeAccountID: accountA.id,
            credentials: [accountA.id: makeCredentials("a")]
        )
        let localIdentity = ProviderAccountIdentity(
            stableAccountID: "subject-b",
            email: "b@example.com"
        )
        let localSnapshot = makeSnapshot(
            identity: localIdentity,
            source: .localApp
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(localSnapshot)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .manual,
                accountTarget: .ambientLocal,
                repositoryRevision: 0,
                connection: makeConnectionSettings(
                    policy: .localSession
                )
            )
        )

        XCTAssertEqual(result, .ready(localSnapshot))
        let state = await repository.stateValue()
        let replaceCount =
            await repository.replaceCountValue()
        XCTAssertEqual(state.activeAccountID, accountA.id)
        XCTAssertEqual(replaceCount, 0)
    }

    func testOAuthCredentialCASAdvancesOwnRevisionWithoutDiscardingUsageOrChangingActiveAccount() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let original = makeCredentials("old")
        let refreshed = makeCredentials("new")
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: original]
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential: refreshed
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )

        XCTAssertEqual(result, .ready(snapshot))
        let state = await repository.stateValue()
        let storedCredentials =
            await repository.credentialsValue(
                for: account.id
            )
        let replaceCount =
            await repository.replaceCountValue()
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.activeAccountID, account.id)
        XCTAssertEqual(storedCredentials, refreshed)
        XCTAssertEqual(replaceCount, 1)
    }

    func testEquivalentStaleRequestWaitingBehindCommitRejoinsCompletedFlight() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let gate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("old")],
            replaceBehavior: .waitBeforeCommit(gate)
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential:
                                makeCredentials("new")
                        )),
                    ])
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )

        let first = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        let equivalent = Task {
            await coordinator.refresh(request)
        }
        await Task.yield()
        await gate.resume()

        let firstResult = await first.value
        let equivalentResult = await equivalent.value
        let replaceCount =
            await repository.replaceCountValue()
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(firstResult, .ready(snapshot))
        XCTAssertEqual(equivalentResult, .ready(snapshot))
        XCTAssertEqual(replaceCount, 1)
        XCTAssertEqual(presentation, .ready(snapshot))
    }

    func testCallerCancelledAtCredentialCommitBarrierReturnsBeforeCommitFinishes() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let gate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("old")],
            replaceBehavior: .waitBeforeCommit(gate)
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential:
                                makeCredentials("new")
                        )),
                    ])
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )

        let owner = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()

        let completion = expectation(
            description: "cancelled commit-barrier caller"
        )
        let resultBox = RefreshPresentationResultBox()
        let barrierCaller = Task {
            let result = await coordinator.refresh(request)
            await resultBox.store(result)
            completion.fulfill()
            return result
        }
        while await coordinator
            .credentialCommitWaiterCountForTesting() == 0
        {
            await Task.yield()
        }

        barrierCaller.cancel()
        await fulfillment(of: [completion], timeout: 1)
        let cancelledResult = await resultBox.value()
        let replaceCountBeforeResume =
            await repository.replaceCountValue()
        XCTAssertEqual(
            cancelledResult,
            .failed(.cancelled)
        )
        XCTAssertEqual(replaceCountBeforeResume, 0)

        await gate.resume()
        let ownerResult = await owner.value
        XCTAssertEqual(ownerResult, .ready(snapshot))
    }

    func testOwnerAndSharedWaiterCancellationDuringCommitReturnsImmediatelyButCommitReconciles() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let original = makeCredentials("old")
        let refreshed = makeCredentials("new")
        let repositoryGate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: original],
            replaceBehavior:
                .waitBeforeCommit(repositoryGate)
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let sourceGate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .googleOAuth,
                    script: sourceGate
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )
        let ownerCompletion = expectation(
            description: "cancelled owner"
        )
        let sharedCompletion = expectation(
            description: "cancelled shared waiter"
        )
        let ownerBox = RefreshPresentationResultBox()
        let sharedBox = RefreshPresentationResultBox()
        let owner = Task {
            let result = await coordinator.refresh(request)
            await ownerBox.store(result)
            ownerCompletion.fulfill()
            return result
        }
        await sourceGate.waitUntilStarted()
        let shared = Task {
            let result = await coordinator.refresh(request)
            await sharedBox.store(result)
            sharedCompletion.fulfill()
            return result
        }
        while await coordinator
            .inFlightWaiterCountForTesting() < 2
        {
            await Task.yield()
        }
        await sourceGate.resume(
            with: .init(
                payload: .grouped(snapshot),
                refreshedCredential: refreshed
            )
        )
        await repositoryGate.waitUntilStarted()

        owner.cancel()
        shared.cancel()
        await fulfillment(
            of: [ownerCompletion, sharedCompletion],
            timeout: 1
        )
        let ownerResult = await ownerBox.value()
        let sharedResult = await sharedBox.value()
        let storedBeforeResume =
            await repository.credentialsValue(for: account.id)
        XCTAssertEqual(ownerResult, .failed(.cancelled))
        XCTAssertEqual(sharedResult, .failed(.cancelled))
        XCTAssertEqual(storedBeforeResume, original)

        let boundary = Task {
            await coordinator.invalidateBoundary()
        }
        await repositoryGate.resume()
        await boundary.value

        let storedAfterCommit =
            await repository.credentialsValue(for: account.id)
        let revision = await repository.stateValue().revision
        XCTAssertEqual(storedAfterCommit, refreshed)
        XCTAssertEqual(revision, 1)
    }

    func testBoundaryInvalidationClearsImmediatelyAndPreventsPreBarrierEpochFromRestarting() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repositoryGate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("old")],
            replaceBehavior:
                .waitBeforeCommit(repositoryGate)
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let sourceScript = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(snapshot))),
            .success(.init(
                payload: .grouped(snapshot),
                refreshedCredential: makeCredentials("new")
            )),
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: sourceScript
                ),
            ]
        )
        let manualRequest = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )
        let initial = await coordinator.refresh(manualRequest)
        XCTAssertEqual(initial, .ready(snapshot))

        let scheduledRequest = AntigravityRefreshRequest(
            trigger: .scheduled,
            accountTarget: .selectedOAuth(account.id),
            repositoryRevision: 0,
            connection: makeConnectionSettings(
                policy: .googleAccount
            )
        )
        let commitOwner = Task {
            await coordinator.refresh(scheduledRequest)
        }
        await repositoryGate.waitUntilStarted()
        let preBoundaryPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(
            preBoundaryPresentation,
            .refreshing(previous: snapshot)
        )

        let preBoundaryCaller = Task {
            await coordinator.refresh(scheduledRequest)
        }
        while await coordinator
            .credentialCommitWaiterCountForTesting() < 1
        {
            await Task.yield()
        }
        let boundary = Task {
            await coordinator.invalidateBoundary()
        }
        while await coordinator
            .credentialCommitWaiterCountForTesting() < 2
        {
            await Task.yield()
        }

        let invalidatedPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(
            invalidatedPresentation,
            .refreshing(previous: nil)
        )
        await repositoryGate.resume()
        await boundary.value
        _ = await commitOwner.value
        let preBoundaryResult = await preBoundaryCaller.value
        let sourceCallCount = await sourceScript.callCount()
        XCTAssertEqual(
            preBoundaryResult,
            .refreshing(previous: nil)
        )
        XCTAssertEqual(sourceCallCount, 2)
    }

    func testCommitFirstBoundaryOrderingReloadsRevisionBeforeAccountSwitchAndClearsOldUsage() async throws {
        let accountA = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let accountB = makeAccount(
            id: "account-b",
            subject: "subject-b",
            email: "b@example.com"
        )
        let gate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [accountA, accountB],
            activeAccountID: accountA.id,
            credentials: [
                accountA.id: makeCredentials("a-old"),
                accountB.id: makeCredentials("b"),
            ],
            replaceBehavior: .waitBeforeCommit(gate)
        )
        let snapshot = makeSnapshot(
            identity: accountA.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential:
                                makeCredentials("a-new")
                        )),
                    ])
                ),
            ]
        )

        let refreshTask = Task {
            await coordinator.refresh(
                selectedRequest(
                    accountID: accountA.id,
                    revision: 0,
                    policy: .googleAccount
                )
            )
        }
        await gate.waitUntilStarted()
        let boundaryTask = Task {
            await coordinator.invalidateBoundary()
        }
        await Task.yield()
        await gate.resume()
        await boundaryTask.value
        _ = await refreshTask.value

        let reloaded = await repository.stateValue()
        XCTAssertEqual(reloaded.revision, 1)
        let switched = try await repository.switchActive(
            to: accountB.id,
            expectedRevision: reloaded.revision
        )
        XCTAssertEqual(switched.activeAccountID, accountB.id)
        XCTAssertEqual(switched.revision, 2)
        let storedCredentials =
            await repository.credentialsValue(
                for: accountA.id
            )
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(
            storedCredentials,
            makeCredentials("a-new")
        )
        XCTAssertEqual(
            presentation,
            .refreshing(previous: nil)
        )
    }

    func testPostCommitCleanupThrowReconcilesCommittedCredentialAndAppliesUsage() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("old")],
            replaceBehavior: .throwAfterCommit
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential:
                                makeCredentials("new")
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )
        XCTAssertEqual(result, .ready(snapshot))
        let committed = await repository.stateValue()
        XCTAssertEqual(committed.revision, 1)
    }

    func testPreCommitThrowReconcilesOriginalCredentialAsTypedFailure() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("old")],
            replaceBehavior: .throwBeforeCommit
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential:
                                makeCredentials("new")
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )
        let storedCredentials =
            await repository.credentialsValue(
                for: account.id
            )
        XCTAssertEqual(
            result,
            .failed(.credentialCommitFailed)
        )
        XCTAssertEqual(
            storedCredentials,
            makeCredentials("old")
        )
    }

    func testConcurrentEquivalentRequestsUseOneSourceFetch() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .googleOAuth,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )

        async let first = coordinator.refresh(request)
        await gate.waitUntilStarted()
        async let second = coordinator.refresh(request)
        await gate.resume(
            with: .init(payload: .grouped(snapshot))
        )

        let values = await [first, second]
        let callCount = await gate.callCount()
        XCTAssertEqual(values, [.ready(snapshot), .ready(snapshot)])
        XCTAssertEqual(callCount, 1)
    }

    func testCancelledWaiterDetachesWithoutCancellingSharedFlight() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .googleOAuth,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )

        let cancelled = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        let survivor = Task {
            await coordinator.refresh(request)
        }
        await Task.yield()
        cancelled.cancel()

        let cancelledResult = await cancelled.value
        let callCount = await gate.callCount()
        XCTAssertEqual(
            cancelledResult,
            .failed(.cancelled)
        )
        XCTAssertEqual(callCount, 1)

        await gate.resume(
            with: .init(payload: .grouped(snapshot))
        )
        let survivorResult = await survivor.value
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(survivorResult, .ready(snapshot))
        XCTAssertEqual(presentation, .ready(snapshot))
    }

    func testCancellingOnlyWaiterCancelsSourceAndRejectsLateCredential() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let original = makeCredentials("old")
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: original]
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .googleOAuth,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )

        let caller = Task {
            await coordinator.refresh(request)
        }
        await gate.waitUntilStarted()
        caller.cancel()

        let callerResult = await caller.value
        XCTAssertEqual(
            callerResult,
            .failed(.cancelled)
        )
        await gate.waitUntilCancellationObserved()
        let initialReplaceCount =
            await repository.replaceCountValue()
        let cancelledPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(initialReplaceCount, 0)
        XCTAssertEqual(
            cancelledPresentation,
            .failed(.cancelled)
        )

        await gate.resume(
            with: .init(
                payload: .grouped(snapshot),
                refreshedCredential: makeCredentials("late")
            )
        )
        await gate.waitUntilFinished()
        await Task.yield()

        let finalReplaceCount =
            await repository.replaceCountValue()
        let storedCredentials =
            await repository.credentialsValue(
                for: account.id
            )
        let finalPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(finalReplaceCount, 0)
        XCTAssertEqual(
            storedCredentials,
            original
        )
        XCTAssertEqual(
            finalPresentation,
            .failed(.cancelled)
        )
    }

    func testQuiesceCancelsNoncooperativeFlightAndRejectsFutureRefresh() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let sourceGate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(
                accounts: [account],
                activeAccountID: account.id,
                credentials: [
                    account.id: makeCredentials("a"),
                ]
            ),
            sources: [
                BlockingRefreshSource(
                    id: .googleOAuth,
                    script: sourceGate
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )
        let callerCompletion = expectation(
            description: "quiesced caller"
        )
        let callerResultBox = RefreshPresentationResultBox()
        let caller = Task {
            let result = await coordinator.refresh(request)
            await callerResultBox.store(result)
            callerCompletion.fulfill()
            return result
        }
        await sourceGate.waitUntilStarted()

        await coordinator.quiesceForShutdown()
        await fulfillment(of: [callerCompletion], timeout: 1)
        let callerResult = await callerResultBox.value()
        let rejected = await coordinator.refresh(request)
        let sourceCallCount = await sourceGate.callCount()
        let presentation = await coordinator.presentationState()
        XCTAssertEqual(callerResult, .failed(.cancelled))
        XCTAssertEqual(rejected, .failed(.appShuttingDown))
        XCTAssertEqual(
            presentation,
            .failed(.appShuttingDown)
        )
        XCTAssertEqual(sourceCallCount, 1)

        await sourceGate.resume(
            with: .init(payload: .grouped(snapshot))
        )
        await sourceGate.waitUntilFinished()
        let completedCaller = await caller.value
        XCTAssertEqual(completedCaller, .failed(.cancelled))
    }

    func testCancelledQuiesceLeavesShutdownClosedWhileCredentialCommitSettles() async {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let original = makeCredentials("old")
        let refreshed = makeCredentials("new")
        let repositoryGate = RefreshRepositoryReplaceGate()
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: original],
            replaceBehavior:
                .waitBeforeCommit(repositoryGate)
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                            payload: .grouped(snapshot),
                            refreshedCredential: refreshed
                        )),
                    ])
                ),
            ]
        )
        let request = selectedRequest(
            accountID: account.id,
            revision: 0,
            policy: .googleAccount
        )
        let ownerCompletion = expectation(
            description: "commit owner quiesced"
        )
        let ownerResultBox = RefreshPresentationResultBox()
        let owner = Task {
            let result = await coordinator.refresh(request)
            await ownerResultBox.store(result)
            ownerCompletion.fulfill()
            return result
        }
        await repositoryGate.waitUntilStarted()

        let quiesceCompletion = expectation(
            description: "cancelled quiesce"
        )
        let quiesce = Task {
            await coordinator.quiesceForShutdown()
            quiesceCompletion.fulfill()
        }
        while await coordinator
            .credentialCommitWaiterCountForTesting() < 1
        {
            await Task.yield()
        }
        await fulfillment(of: [ownerCompletion], timeout: 1)
        quiesce.cancel()
        await fulfillment(of: [quiesceCompletion], timeout: 1)

        let ownerResult = await ownerResultBox.value()
        let storedBeforeCommit =
            await repository.credentialsValue(for: account.id)
        let rejected = await coordinator.refresh(request)
        XCTAssertEqual(ownerResult, .failed(.cancelled))
        XCTAssertEqual(storedBeforeCommit, original)
        XCTAssertEqual(rejected, .failed(.appShuttingDown))

        await repositoryGate.resume()
        await coordinator.quiesceForShutdown()

        let storedAfterCommit =
            await repository.credentialsValue(for: account.id)
        let repositoryState = await repository.stateValue()
        let finalPresentation =
            await coordinator.presentationState()
        XCTAssertEqual(storedAfterCommit, refreshed)
        XCTAssertEqual(repositoryState.revision, 1)
        XCTAssertEqual(
            finalPresentation,
            .failed(.appShuttingDown)
        )
        let completedOwner = await owner.value
        XCTAssertEqual(completedOwner, .failed(.cancelled))
    }

    func testNormalFailureKeepsLastGoodButBoundaryFailureClearsIt() async throws {
        let account = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [account],
            activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")]
        )
        let snapshot = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let script = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(snapshot))),
            .failure(.unavailable),
            .failure(.unavailable),
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .googleOAuth,
                    script: script
                ),
            ]
        )

        let initial = await coordinator.refresh(
            selectedRequest(
                accountID: account.id,
                revision: 0,
                policy: .googleAccount
            )
        )
        XCTAssertEqual(initial, .ready(snapshot))

        let stale = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .scheduled,
                accountTarget: .selectedOAuth(account.id),
                repositoryRevision: 0,
                connection: makeConnectionSettings(
                    policy: .googleAccount
                )
            )
        )
        XCTAssertEqual(
            stale,
            .stale(
                snapshot,
                failure: .sourceUnavailable(.googleOAuth)
            )
        )

        let cleared = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .sourceBoundaryChanged,
                accountTarget: .selectedOAuth(account.id),
                repositoryRevision: 0,
                connection: makeConnectionSettings(
                    policy: .googleAccount
                )
            )
        )
        XCTAssertEqual(
            cleared,
            .failed(.sourceUnavailable(.googleOAuth))
        )
    }

    func testBoundaryCancellationDiscardsLateUsageAndRefreshedCredential() async throws {
        let accountA = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let accountB = makeAccount(
            id: "account-b",
            subject: "subject-b",
            email: "b@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [accountA, accountB],
            activeAccountID: accountA.id,
            credentials: [
                accountA.id: makeCredentials("a-old"),
                accountB.id: makeCredentials("b"),
            ]
        )
        let aSnapshot = makeSnapshot(
            identity: accountA.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let bSnapshot = makeSnapshot(
            identity: accountB.externalIdentity
                .providerAccountIdentity,
            source: .googleOAuth
        )
        let script = AccountSwitchRefreshSourceScript(
            blockedAccountID: accountA.id,
            immediateResponses: [
                accountB.id: .init(
                    payload: .grouped(bSnapshot)
                ),
            ]
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                AccountSwitchRefreshSource(script: script),
            ]
        )

        let oldCompletion = expectation(
            description: "superseded noncooperative caller"
        )
        let oldResultBox = RefreshPresentationResultBox()
        let oldTask = Task {
            let result = await coordinator.refresh(
                selectedRequest(
                    accountID: accountA.id,
                    revision: 0,
                    policy: .googleAccount
                )
            )
            await oldResultBox.store(result)
            oldCompletion.fulfill()
            return result
        }
        await script.waitUntilBlockedRequestStarts()
        await coordinator.invalidateBoundary()
        await fulfillment(of: [oldCompletion], timeout: 1)
        let oldResult = await oldResultBox.value()
        XCTAssertEqual(oldResult, .failed(.cancelled))

        let newState = try await repository.switchActive(
            to: accountB.id,
            expectedRevision: 0
        )

        async let newResult = coordinator.refresh(
            selectedRequest(
                accountID: accountB.id,
                revision: newState.revision,
                policy: .googleAccount
            )
        )
        await script.resumeBlockedRequest(
            with: .init(
                payload: .grouped(aSnapshot),
                refreshedCredential:
                    makeCredentials("a-late")
            )
        )

        let newPresentation = await newResult
        let completedOldResult = await oldTask.value
        XCTAssertEqual(
            completedOldResult,
            .failed(.cancelled)
        )
        let replaceCount =
            await repository.replaceCountValue()
        let oldCredentials =
            await repository.credentialsValue(
                for: accountA.id
            )
        let presentation =
            await coordinator.presentationState()
        XCTAssertEqual(newPresentation, .ready(bSnapshot))
        XCTAssertEqual(replaceCount, 0)
        XCTAssertEqual(
            oldCredentials,
            makeCredentials("a-old")
        )
        XCTAssertEqual(
            presentation,
            .ready(bSnapshot)
        )
    }
}

private actor RefreshPresentationResultBox {
    private var result: AntigravityPresentationState?

    func store(_ result: AntigravityPresentationState) {
        self.result = result
    }

    func value() -> AntigravityPresentationState? {
        result
    }
}

private actor RefreshRepositoryDouble:
    AntigravityRefreshAccountRepository
{
    private var storedState: AntigravityAccountRepositoryState
    private var credentials:
        [AntigravityAccountID: AntigravityOAuthCredentials]
    private var replaceCount = 0
    private let replaceBehavior: RefreshRepositoryReplaceBehavior

    init(
        accounts: [AntigravityStoredAccount],
        activeAccountID: AntigravityAccountID?,
        credentials:
            [AntigravityAccountID: AntigravityOAuthCredentials],
        replaceBehavior:
            RefreshRepositoryReplaceBehavior = .normal
    ) {
        storedState = AntigravityAccountRepositoryState(
            revision: 0,
            activeAccountID: activeAccountID,
            accounts: accounts
        )
        self.credentials = credentials
        self.replaceBehavior = replaceBehavior
    }

    func state() async throws -> AntigravityAccountRepositoryState {
        storedState
    }

    func credentialSnapshot(
        for accountID: AntigravityAccountID
    ) async throws -> AntigravityCredentialSnapshot? {
        guard let account = storedState.accounts.first(
            where: { $0.id == accountID }
        ), let credentials = credentials[accountID] else {
            return nil
        }
        return AntigravityCredentialSnapshot(
            repositoryRevision: storedState.revision,
            account: account,
            credentials: credentials
        )
    }

    func replaceCredential(
        for accountID: AntigravityAccountID,
        with credentials: AntigravityOAuthCredentials,
        externalIdentity: AntigravityExternalAccountIdentity?,
        expectedRevision: UInt64
    ) async throws -> AntigravityAccountRepositoryState {
        switch replaceBehavior {
        case .throwBeforeCommit:
            throw RefreshRepositoryFault.injected
        case .waitBeforeCommit(let gate):
            await gate.markStartedAndWait()
        case .normal, .throwAfterCommit:
            break
        }
        guard storedState.revision == expectedRevision else {
            throw AntigravityAccountRepositoryError
                .revisionConflict(
                    expected: expectedRevision,
                    actual: storedState.revision
                )
        }
        guard storedState.accounts.contains(
            where: { $0.id == accountID }
        ) else {
            throw AntigravityAccountRepositoryError
                .accountNotFound
        }
        replaceCount += 1
        self.credentials[accountID] = credentials
        storedState.revision += 1
        if case .throwAfterCommit = replaceBehavior {
            throw RefreshRepositoryFault.injected
        }
        return storedState
    }

    func switchActive(
        to accountID: AntigravityAccountID,
        expectedRevision: UInt64
    ) throws -> AntigravityAccountRepositoryState {
        guard storedState.revision == expectedRevision else {
            throw AntigravityAccountRepositoryError
                .revisionConflict(
                    expected: expectedRevision,
                    actual: storedState.revision
                )
        }
        storedState.activeAccountID = accountID
        storedState.revision += 1
        return storedState
    }

    func stateValue() -> AntigravityAccountRepositoryState {
        storedState
    }

    func credentialsValue(
        for accountID: AntigravityAccountID
    ) -> AntigravityOAuthCredentials? {
        credentials[accountID]
    }

    func replaceCountValue() -> Int {
        replaceCount
    }
}

private enum RefreshRepositoryFault: Error {
    case injected
}

private enum RefreshRepositoryReplaceBehavior:
    Sendable
{
    case normal
    case throwBeforeCommit
    case throwAfterCommit
    case waitBeforeCommit(RefreshRepositoryReplaceGate)
}

private actor RefreshRepositoryReplaceGate {
    private var started = false
    private var startedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation:
        CheckedContinuation<Void, Never>?

    func markStartedAndWait() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation {
            resumeContinuation = $0
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startedWaiters.append($0)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor RefreshSourceScript {
    struct Call: Sendable {
        let hasOAuthAuthorization: Bool
    }

    private var outcomes:
        [Result<
            AntigravityUsageSourceResponse,
            AntigravityUsageSourceError
        >]
    private var calls: [Call] = []

    init(
        outcomes: [Result<
            AntigravityUsageSourceResponse,
            AntigravityUsageSourceError
        >]
    ) {
        self.outcomes = outcomes
    }

    func next(
        _ request: AntigravityUsageSourceRequest
    ) throws -> AntigravityUsageSourceResponse {
        calls.append(Call(
            hasOAuthAuthorization:
                request.oauthAuthorization != nil
        ))
        guard !outcomes.isEmpty else {
            throw AntigravityUsageSourceError.unavailable
        }
        return try outcomes.removeFirst().get()
    }

    func callCount() -> Int {
        calls.count
    }

    func authorizationFlags() -> [Bool] {
        calls.map(\.hasOAuthAuthorization)
    }
}

private struct ScriptedRefreshSource:
    AntigravityUsageSource
{
    let id: AntigravityUsageSourceID
    let script: RefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try await script.next(request)
    }
}

private actor ConnectionSnapshotRefreshSourceScript {
    private let response: AntigravityUsageSourceResponse
    private var observedIdleTimeouts: [Duration?] = []
    private var firstStarted = false
    private var firstStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var firstContinuation:
        CheckedContinuation<
            AntigravityUsageSourceResponse,
            Never
        >?

    init(response: AntigravityUsageSourceResponse) {
        self.response = response
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async -> AntigravityUsageSourceResponse {
        observedIdleTimeouts.append(
            request.managedLaunchAuthorization.idleTimeout
        )
        if observedIdleTimeouts.count > 1 {
            return response
        }

        firstStarted = true
        let waiters = firstStartedWaiters
        firstStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation {
            firstContinuation = $0
        }
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation {
            firstStartedWaiters.append($0)
        }
    }

    func resumeFirst() {
        firstContinuation?.resume(returning: response)
        firstContinuation = nil
    }

    func idleTimeouts() -> [Duration] {
        observedIdleTimeouts.compactMap { $0 }
    }
}

private struct ConnectionSnapshotRefreshSource:
    AntigravityUsageSource
{
    let id = AntigravityUsageSourceID.managedCLI
    let script: ConnectionSnapshotRefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        await script.fetch(request)
    }
}

private actor BlockingRefreshSourceScript {
    private var calls = 0
    private var started = false
    private var startedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var responseContinuation:
        CheckedContinuation<
            AntigravityUsageSourceResponse,
            Never
        >?
    private var cancellationObserved = false
    private var cancellationWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var finished = false
    private var finishedWaiters:
        [CheckedContinuation<Void, Never>] = []

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        calls += 1
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        defer {
            finished = true
            let waiters = finishedWaiters
            finishedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                responseContinuation = $0
            }
        } onCancel: {
            Task {
                await self.markCancellationObserved()
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startedWaiters.append($0)
        }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation {
            cancellationWaiters.append($0)
        }
    }

    private func markCancellationObserved() {
        cancellationObserved = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resume(
        with response: AntigravityUsageSourceResponse
    ) {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation {
            finishedWaiters.append($0)
        }
    }

    func callCount() -> Int {
        calls
    }
}

private struct BlockingRefreshSource:
    AntigravityUsageSource
{
    let id: AntigravityUsageSourceID
    let script: BlockingRefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try await script.fetch(request)
    }
}

private actor AccountSwitchRefreshSourceScript {
    private let blockedAccountID: AntigravityAccountID
    private let immediateResponses:
        [AntigravityAccountID:
            AntigravityUsageSourceResponse]
    private var blockedStarted = false
    private var blockedStartedWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var blockedContinuation:
        CheckedContinuation<
            AntigravityUsageSourceResponse,
            Never
        >?

    init(
        blockedAccountID: AntigravityAccountID,
        immediateResponses:
            [AntigravityAccountID:
                AntigravityUsageSourceResponse]
    ) {
        self.blockedAccountID = blockedAccountID
        self.immediateResponses = immediateResponses
    }

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        guard let accountID =
                request.oauthAuthorization?.accountID
        else {
            throw AntigravityUsageSourceError
                .authenticationRequired
        }
        if accountID != blockedAccountID {
            guard let response =
                    immediateResponses[accountID]
            else {
                throw AntigravityUsageSourceError.unavailable
            }
            return response
        }

        blockedStarted = true
        let waiters = blockedStartedWaiters
        blockedStartedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation {
            blockedContinuation = $0
        }
    }

    func waitUntilBlockedRequestStarts() async {
        guard !blockedStarted else { return }
        await withCheckedContinuation {
            blockedStartedWaiters.append($0)
        }
    }

    func resumeBlockedRequest(
        with response: AntigravityUsageSourceResponse
    ) {
        blockedContinuation?.resume(returning: response)
        blockedContinuation = nil
    }
}

private struct AccountSwitchRefreshSource:
    AntigravityUsageSource
{
    let id = AntigravityUsageSourceID.googleOAuth
    let script: AccountSwitchRefreshSourceScript

    func fetch(
        _ request: AntigravityUsageSourceRequest
    ) async throws -> AntigravityUsageSourceResponse {
        try await script.fetch(request)
    }
}

private func selectedRequest(
    accountID: AntigravityAccountID,
    revision: UInt64,
    policy: AntigravityConnectionSettings.SourcePolicy
) -> AntigravityRefreshRequest {
    AntigravityRefreshRequest(
        trigger: .manual,
        accountTarget: .selectedOAuth(accountID),
        repositoryRevision: revision,
        connection: makeConnectionSettings(policy: policy)
    )
}

private func makeConnectionSettings(
    policy: AntigravityConnectionSettings.SourcePolicy,
    allowManagedCLI: Bool = false,
    managedIdleTimeoutSeconds: Int =
        AntigravityConnectionSettings
            .ManagedSessionPolicy
            .defaultIdleTimeoutSeconds
) -> AntigravityConnectionSettings {
    AntigravityConnectionSettings(
        schemaVersion:
            AntigravityConnectionSettings.currentSchemaVersion,
        sourcePolicy: policy,
        allowManagedCLI: allowManagedCLI,
        managedSession: .init(
            idleTimeoutSeconds: managedIdleTimeoutSeconds
        )
    )
}

private func makeAccount(
    id: String,
    subject: String?,
    email: String?
) -> AntigravityStoredAccount {
    AntigravityStoredAccount(
        id: AntigravityAccountID(rawValue: id),
        label: email ?? id,
        externalIdentity: .init(
            googleSubject: subject,
            email: email
        ),
        migrationAliases: [],
        lifecycle: .active,
        credentialReference:
            AntigravityCredentialReference(
                rawValue:
                    "\(AntigravityCredentialReference.namespacePrefix)\(id)"
            ),
        createdAtMilliseconds: 1,
        updatedAtMilliseconds: 1
    )
}

private func makeCredentials(
    _ seed: String
) -> AntigravityOAuthCredentials {
    AntigravityOAuthCredentials(
        accessToken: "access-\(seed)",
        refreshToken: "refresh-\(seed)",
        expiryDate: Date(timeIntervalSince1970: 2_000_000_000),
        email: "a@example.com",
        clientID: "client",
        clientSecret: "secret"
    )
}

private func makeSnapshot(
    identity: ProviderAccountIdentity?,
    source: AntigravityUsageSourceID
) -> AntigravityQuotaSnapshot {
    let provenance = makeProvenance(
        identity: identity,
        source: source,
        capability: .groupedQuotaSummary
    )

    return AntigravityQuotaSnapshot(
        identity: identity,
        plan: "Pro",
        lanes: [
            AntigravityQuotaLane(
                id: .geminiFiveHour,
                upstreamGroupID: "gemini",
                upstreamBucketID: "five-hour",
                scope: .gemini,
                cadence: .fiveHour,
                remainingFraction: 0.75,
                resetAt: Date(timeIntervalSince1970: 2_000_000_000),
                resetDescription: nil,
                availability: .available
            ),
        ],
        decodeIssues: [],
        provenance: provenance,
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
}

private func makeIdentityOnlyUsage(
    identity: ProviderAccountIdentity,
    source: AntigravityUsageSourceID
) -> AntigravityIdentityOnlyUsage {
    AntigravityIdentityOnlyUsage(
        identity: identity,
        plan: "Pro",
        provenance: makeProvenance(
            identity: identity,
            source: source,
            capability: .groupedQuotaSummary
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_001)
    )
}

private func makeGoogleOAuthLimitedCapability(
    identity: ProviderAccountIdentity
) -> AntigravityLimitedQuotaCapability {
    .googleOAuth(
        evidence:
            AntigravityGoogleOAuthLimitedQuotaEvidence(
                identity: identity,
                plan: "Pro",
                modelQuotaCount: 2
            ),
        provenance: makeProvenance(
            identity: identity,
            source: .googleOAuth,
            capability: .limitedQuota
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_900_000_002)
    )
}

private func makeLocalLimitedCapability(
    identity: ProviderAccountIdentity
) -> AntigravityLimitedQuotaCapability {
    .localLegacy(
        evidence:
            AntigravityLegacyCapabilityEvidence(
                method: .getUserStatus,
                identity: identity,
                plan: "Pro",
                modelConfigCount: 2
            ),
        fallbackReason: .groupedQuotaUnavailable,
        provenance: makeProvenance(
            identity: identity,
            source: .localApp,
            capability: .limitedQuota
        ),
        fetchedAt: Date(
            timeIntervalSince1970: 1_900_000_002
        )
    )
}

private func makeProvenance(
    identity: ProviderAccountIdentity?,
    source: AntigravityUsageSourceID,
    capability: AntigravityQuotaProvenance.Capability
) -> AntigravityQuotaProvenance {
    let transport: AntigravityQuotaProvenance.Transport
    let owner: AntigravityQuotaProvenance.EndpointOwner
    let processIdentity: ProcessIdentity?
    switch source {
    case .localApp:
        transport = .localAppRPC
        owner = .external
        processIdentity = ProcessIdentity(
            processID: 101,
            startedAt: Date(timeIntervalSince1970: 100),
            executablePath: "/Applications/Antigravity.app/agy"
        )
    case .borrowedCLI:
        transport = .borrowedAGYRPC
        owner = .borrowed
        processIdentity = ProcessIdentity(
            processID: 102,
            startedAt: Date(timeIntervalSince1970: 100),
            executablePath: "/usr/local/bin/agy"
        )
    case .managedCLI:
        transport = .managedAGYRPC
        owner = .managed
        processIdentity = ProcessIdentity(
            processID: 103,
            startedAt: Date(timeIntervalSince1970: 100),
            executablePath: "/usr/local/bin/agy"
        )
    case .googleOAuth:
        transport = .googleOAuth
        owner = .external
        processIdentity = nil
    }

    return AntigravityQuotaProvenance(
        transport: transport,
        endpointOwner: owner,
        accountIdentity: identity,
        capability: capability,
        processIdentity: processIdentity
    )
}
