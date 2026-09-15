import XCTest
@testable import ClaudeUsage

final class AntigravityRefreshCoordinatorTests: XCTestCase {
    func testNewAuthenticatedAccountWithQuotaFailureNeverKeepsPreviousAccountData() async {
        let previous = ProviderAccountIdentity(email: "old@example.com")
        let next = ProviderAccountIdentity(email: "new@example.com")
        for identity in [previous, next] {
            let quota = makeSnapshot(identity: previous, source: .borrowedCLI)
            let coordinator = AntigravityRefreshCoordinator(
                repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
                sources: [
                    ScriptedRefreshSource(
                        id: .borrowedCLI,
                        script: RefreshSourceScript(outcomes: [
                            .success(.init(payload: .grouped(quota))),
                            .failure(.verifiedAccountFailure(identity, .transportFailure)),
                        ]))
                ])
            _ = await coordinator.refresh(selectedRequest(revision: 0))
            let result = await coordinator.refresh(selectedRequest(revision: 0))
            if identity == previous {
                XCTAssertEqual(result, .stale(quota, failure: .transportUnavailable(.borrowedCLI)))
            } else {
                XCTAssertEqual(result, .failed(.transportUnavailable(.borrowedCLI)))
            }
        }
    }

    func testUnselectedProductNeverProbesAnySource() async {
        let script = RefreshSourceScript(outcomes: [.failure(.transportFailure)])
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [ScriptedRefreshSource(id: .borrowedCLI, script: script)])
        let result = await coordinator.refresh(selectedRequest(target: .unselected, revision: 0))
        let calls = await script.callCount()
        XCTAssertEqual(result, .setupRequired(.usageTargetSelection))
        XCTAssertEqual(calls, 0)
    }

    func testCLILoginChangeReplacesQuotaAndDoesNotRestoreItAfterLogout() async {
        let a = makeSnapshot(identity: .init(email: "a@example.com"), source: .borrowedCLI)
        let b = makeSnapshot(identity: .init(email: "b@example.com"), source: .borrowedCLI, fraction: 0.2)
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(a))), .success(.init(payload: .grouped(b))),
                        .failure(.authenticationRequired),
                    ]))
            ])
        let request = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0,
            connection: makeConnectionSettings(), managedLaunch: .disabled)
        let first = await coordinator.refresh(request)
        let second = await coordinator.refresh(request)
        let loggedOut = await coordinator.refresh(request)
        XCTAssertEqual(first, .ready(a))
        XCTAssertEqual(second, .ready(b))
        XCTAssertEqual(loggedOut, .failed(.authenticationRequired(.borrowedCLI)))
    }

    func testLocalSelectionRejectsOtherAccountWithoutRequiringOAuth() async {
        let selected = ProviderAccountIdentity(stableAccountID: "a", email: "a@example.com")
        let other = ProviderAccountIdentity(stableAccountID: "b", email: "b@example.com")
        let expected = makeSnapshot(identity: selected, source: .borrowedCLI)
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(makeSnapshot(identity: other, source: .localApp))))
                    ])),
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(expected)))
                    ])),
            ])
        let result = await coordinator.refresh(
            .init(
                trigger: .manual, repositoryRevision: 0,
                connection: makeConnectionSettings(), managedLaunch: .disabled))
        XCTAssertEqual(result, .ready(expected))
    }

    func testAppLoginChangeReplacesIdentityAndQuotaTogether() async {
        let selected = ProviderAccountIdentity(stableAccountID: "a", email: "a@example.com")
        let other = ProviderAccountIdentity(stableAccountID: "b", email: "b@example.com")
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(makeSnapshot(identity: selected, source: .localApp)))),
                        .success(.init(payload: .grouped(makeSnapshot(identity: other, source: .localApp)))),
                    ]))
            ])
        let request = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0,
            connection: makeConnectionSettings(target: .app), managedLaunch: .disabled)
        _ = await coordinator.refresh(request)
        let result = await coordinator.refresh(request)
        XCTAssertEqual(result, .ready(makeSnapshot(identity: other, source: .localApp)))
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
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .disabled
            )
        )

        XCTAssertEqual(
            result,
            .failed(.sourceUnavailable(.borrowedCLI))
        )
    }

    func testRecoveryBlockedAmbientRefreshNamesRecoveryInsteadOfLogin() async {
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
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .recoveryBlocked
            )
        )

        XCTAssertEqual(
            result,
            .setupRequired(.managedRecoveryBlocked)
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
            repositoryRevision: 0,
            connection: makeConnectionSettings(
                managedIdleTimeoutSeconds: 31
            ),
            managedLaunch: .enabled
        )
        let secondRequest = AntigravityRefreshRequest(
            trigger: .manual,
            repositoryRevision: 0,
            connection: makeConnectionSettings(
                managedIdleTimeoutSeconds: 47
            ),
            managedLaunch: .enabled
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

    func testLocalAuthenticationFailureRemainsTyped() async {
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
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .failure(.authenticationRequired),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(

                revision: 0
            )
        )
        XCTAssertEqual(
            result,
            .failed(.authenticationRequired(.borrowedCLI))
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
                    .deadlineExceeded(.borrowedCLI)
            ),
            (
                .malformedResponse,
                    .schemaChanged(.borrowedCLI)
            ),
            (
                .transportFailure,
                    .transportUnavailable(.borrowedCLI)
            ),
            (
                .interactionRequired,
                    .interactionRequired(.borrowedCLI)
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
                        id: .borrowedCLI,
                        script: RefreshSourceScript(outcomes: [
                            .failure(sourceError),
                        ])
                    ),
                ]
            )

            let result = await coordinator.refresh(
                selectedRequest(

                    revision: 0
                )
            )
            XCTAssertEqual(
                result,
                .failed(expectedFailure)
            )
        }
    }

    func testCLISelectionIgnoresTheDifferentAppAccount() async throws {
        let accountA = makeAccount(
            id: "account-a",
            subject: "subject-a",
            email: "a@example.com"
        )
        let repository = RefreshRepositoryDouble(
            accounts: [accountA],
            activeAccountID: accountA.id,
            credentials: [
                accountA.id: makeCredentials("a")
            ]
        )
        let localScript = RefreshSourceScript(outcomes: [
            .success(
                .init(
                    payload: .grouped(
                        makeSnapshot(
                            identity: .init(
                                stableAccountID: "subject-b",
                                email: "b@example.com"
                            ),
                            source: .localApp
                        )
                    )))
        ])
        let borrowedSnapshot = makeSnapshot(
            identity: accountA.externalIdentity
                .providerAccountIdentity,
            source: .borrowedCLI
        )
        let borrowedScript = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(borrowedSnapshot)))
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: localScript
                ),
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: borrowedScript
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(

                revision: 0
            )
        )

        XCTAssertEqual(result, .ready(borrowedSnapshot))
        let localCallCount = await localScript.callCount()
        let borrowedCallCount = await borrowedScript.callCount()
        XCTAssertEqual(localCallCount, 0)
        XCTAssertEqual(borrowedCallCount, 1)
    }

    func testAppSelectionDoesNotFallBackToCLIWhenIdentityIsMissing() async throws {
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
        let borrowed = makeSnapshot(
            identity: account.externalIdentity
                .providerAccountIdentity,
            source: .borrowedCLI
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .localApp,
                    script: RefreshSourceScript(outcomes: [
                        .success(
                            .init(
                                payload: .grouped(identityless)
                            ))
                    ])
                ),
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(
                                payload: .grouped(borrowed)
                        )),
                    ])
                ),
            ]
        )

        let result = await coordinator.refresh(
            selectedRequest(
                target: .app,

                revision: 0
            )
        )
        XCTAssertEqual(result, .failed(.sourceContractViolation(.localApp)))
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
            source: .borrowedCLI
        )
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .borrowedCLI,
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

                revision: 0
            )
        )

        XCTAssertEqual(result, .identityOnly(observation))
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
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .app),
                managedLaunch: .disabled
            )
        )

        XCTAssertEqual(result, .ready(localSnapshot))
        let state = await repository.stateValue()
        let replaceCount =
            await repository.replaceCountValue()
        XCTAssertEqual(state.activeAccountID, accountA.id)
        XCTAssertEqual(replaceCount, 0)
    }

    func testManualRefreshDoesNotJoinScheduledFlight() async throws {
        let account = makeAccount(id: "account-a", subject: "subject-a", email: "a@example.com")
        let repository = RefreshRepositoryDouble(accounts: [account], activeAccountID: account.id,
            credentials: [account.id: makeCredentials("a")])
        let snapshot = makeSnapshot(identity: account.externalIdentity.providerAccountIdentity, source: .borrowedCLI)
        let source = DiscoveryPolicySource(snapshot: snapshot)
        let coordinator = AntigravityRefreshCoordinator(repository: repository, sources: [source])
        let scheduled = AntigravityRefreshRequest(
            trigger: .scheduled, repositoryRevision: 0, connection: makeConnectionSettings(target: .cli),
            managedLaunch: .disabled)
        let first = Task { await coordinator.refresh(scheduled) }
        await source.waitUntilStarted()
        let manual = selectedRequest(revision: 0)
        let result = await coordinator.refresh(manual)
        _ = await first.value
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(result, .ready(snapshot))
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
            source: .borrowedCLI
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .borrowedCLI,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(

            revision: 0
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
            source: .borrowedCLI
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .borrowedCLI,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(

            revision: 0
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

    func testCancellingOnlyWaiterCancelsSourceAndRejectsLateUsage() async throws {
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
            source: .borrowedCLI
        )
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                BlockingRefreshSource(
                    id: .borrowedCLI,
                    script: gate
                ),
            ]
        )
        let request = selectedRequest(

            revision: 0
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
                payload: .grouped(snapshot)
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
            source: .borrowedCLI
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
                    id: .borrowedCLI,
                    script: sourceGate
                ),
            ]
        )
        let request = selectedRequest(

            revision: 0
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
            source: .borrowedCLI
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
                    id: .borrowedCLI,
                    script: script
                ),
            ]
        )

        let initial = await coordinator.refresh(
            selectedRequest(

                revision: 0
            )
        )
        XCTAssertEqual(initial, .ready(snapshot))

        let stale = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .scheduled,
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .disabled
            )
        )
        XCTAssertEqual(
            stale,
            .stale(
                snapshot,
                failure: .sourceUnavailable(.borrowedCLI)
            )
        )

        let cleared = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .accountBoundaryChanged,
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .disabled
            )
        )
        XCTAssertEqual(
            cleared,
            .failed(.sourceUnavailable(.borrowedCLI))
        )
    }

    func testCSRFFailureKeepsTimestampUntilExplicitAccountBoundary() async throws {
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
            source: .borrowedCLI
        )
        let script = RefreshSourceScript(outcomes: [
            .success(.init(payload: .grouped(snapshot))),
            .failure(.localAuthentication(.rejected)),
            .failure(.localAuthentication(.rejected)),
        ])
        let coordinator = AntigravityRefreshCoordinator(
            repository: repository,
            sources: [
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: script
                ),
            ]
        )

        let initial = await coordinator.refresh(
            selectedRequest(

                revision: 0
            )
        )
        XCTAssertEqual(initial, .ready(snapshot))

        let stale = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .scheduled,
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .disabled
            )
        )
        XCTAssertEqual(
            stale,
            .stale(
                snapshot,
                failure: .localAuthentication(.borrowedCLI, .rejected)
            )
        )

        let cleared = await coordinator.refresh(
            AntigravityRefreshRequest(
                trigger: .accountBoundaryChanged,
                repositoryRevision: 0,
                connection: makeConnectionSettings(target: .cli),
                managedLaunch: .disabled
            )
        )
        XCTAssertEqual(
            cleared,
            .failed(.localAuthentication(.borrowedCLI, .rejected))
        )
    }

    func testTargetChangeDiscardsLateUsageFromThePreviousProduct() async throws {
        let appIdentity = ProviderAccountIdentity(email: "app@example.com")
        let cliIdentity = ProviderAccountIdentity(email: "cli@example.com")
        let appQuota = makeSnapshot(identity: appIdentity, source: .localApp)
        let cliQuota = makeSnapshot(identity: cliIdentity, source: .borrowedCLI)
        let gate = BlockingRefreshSourceScript()
        let coordinator = AntigravityRefreshCoordinator(
            repository: RefreshRepositoryDouble(accounts: [], activeAccountID: nil, credentials: [:]),
            sources: [
                BlockingRefreshSource(id: .localApp, script: gate),
                ScriptedRefreshSource(
                    id: .borrowedCLI,
                    script: RefreshSourceScript(outcomes: [
                        .success(.init(payload: .grouped(cliQuota)))
                    ])),
            ])
        let old = Task { await coordinator.refresh(selectedRequest(target: .app, revision: 0)) }
        await gate.waitUntilStarted()
        await coordinator.invalidateBoundary()
        let current = await coordinator.refresh(selectedRequest(target: .cli, revision: 0))
        await gate.resume(with: .init(payload: .grouped(appQuota)))
        let cancelled = await old.value
        let final = await coordinator.presentationState()
        XCTAssertEqual(cancelled, .failed(.cancelled))
        XCTAssertEqual(current, .ready(cliQuota))
        XCTAssertEqual(final, .ready(cliQuota))
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

    init(
        accounts: [AntigravityStoredAccount],
        activeAccountID: AntigravityAccountID?,
        credentials:
            [AntigravityAccountID: AntigravityOAuthCredentials]
    ) {
        storedState = AntigravityAccountRepositoryState(
            revision: 0,
            activeAccountID: activeAccountID,
            accounts: accounts
        )
        self.credentials = credentials
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

private actor RefreshSourceScript {
    private var outcomes:
        [Result<
            AntigravityUsageSourceResponse,
            AntigravityUsageSourceError
        >]
    private var calls = 0

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
        calls += 1
        guard !outcomes.isEmpty else {
            throw AntigravityUsageSourceError.unavailable
        }
        return try outcomes.removeFirst().get()
    }

    func callCount() -> Int {
        calls
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

private func selectedRequest(
    target: AntigravityUsageTarget = .cli,
    revision: UInt64
) -> AntigravityRefreshRequest {
    return AntigravityRefreshRequest(
        trigger: .manual,
        repositoryRevision: revision,
        connection: makeConnectionSettings(target: target),
        managedLaunch: .disabled
    )
}

private func makeConnectionSettings(
    target: AntigravityUsageTarget = .cli,
    managedIdleTimeoutSeconds: Int =
        AntigravityConnectionSettings
            .ManagedSessionPolicy
            .defaultIdleTimeoutSeconds
) -> AntigravityConnectionSettings {
    AntigravityConnectionSettings(
        schemaVersion:
            AntigravityConnectionSettings.currentSchemaVersion,
        managedSession: .init(
            idleTimeoutSeconds: managedIdleTimeoutSeconds
        ), usageTarget: target
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
    source: AntigravityUsageSourceID,
    fraction: Double = 0.75
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
                remainingFraction: fraction,
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

private actor DiscoveryPolicySource: AntigravityUsageSource {
    nonisolated let id = AntigravityUsageSourceID.borrowedCLI
    let snapshot: AntigravityQuotaSnapshot
    var calls = 0
    init(snapshot: AntigravityQuotaSnapshot) { self.snapshot = snapshot }
    func waitUntilStarted() async { while calls == 0 { await Task.yield() } }
    func fetch(_ request: AntigravityUsageSourceRequest) async throws -> AntigravityUsageSourceResponse {
        calls += 1
        if calls == 1 { try await Task.sleep(for: .seconds(2)) }
        return .init(payload: .grouped(snapshot))
    }
}
