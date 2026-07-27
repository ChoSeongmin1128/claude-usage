import Foundation
import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeOwnershipRegistryTests:
    XCTestCase
{
    func testOnlyExactRegisteredIdentityIsManaged()
        async
    {
        let registry = AntigravityManagedRuntimeRegistry()
        let registered = makeIdentity(
            processID: 5_101,
            startedAtSeconds: 100
        )
        let reusedPID = makeIdentity(
            processID: 5_101,
            startedAtSeconds: 101
        )

        let initiallyRegisteredOwnership =
            await registry.ownership(for: registered)
        XCTAssertEqual(initiallyRegisteredOwnership, .borrowed)
        await registry.register(registered)
        let registeredOwnership =
            await registry.ownership(for: registered)
        let reusedOwnership =
            await registry.ownership(for: reusedPID)
        XCTAssertEqual(registeredOwnership, .managed)
        XCTAssertEqual(reusedOwnership, .borrowed)
    }

    func testUnregisterReturnsRuntimeToBorrowed()
        async
    {
        let registry = AntigravityManagedRuntimeRegistry()
        let identity = makeIdentity(
            processID: 5_102,
            startedAtSeconds: 102
        )

        await registry.register(identity)
        await registry.unregister(identity)

        let ownership = await registry.ownership(for: identity)
        XCTAssertEqual(ownership, .borrowed)
    }

    func testQuarantinedIdentityIsNeverBorrowed()
        async
    {
        let registry = AntigravityManagedRuntimeRegistry()
        let identity = makeIdentity(
            processID: 5_104,
            startedAtSeconds: 104
        )
        let reusedPID = makeIdentity(
            processID: 5_104,
            startedAtSeconds: 105
        )

        await registry.register(identity)
        await registry.quarantine(identity)

        let quarantined = await registry.ownership(
            for: identity
        )
        let reused = await registry.ownership(for: reusedPID)
        XCTAssertEqual(quarantined, .quarantined)
        XCTAssertEqual(reused, .borrowed)
    }

    func testAppLanguageServerAlwaysRemainsExternal()
        async
    {
        let registry = AntigravityManagedRuntimeRegistry()
        let bundle = AntigravityAppBundleIdentity(
            canonicalRootURL: URL(
                fileURLWithPath: "/Applications/Antigravity.app"
            ),
            bundleIdentifier:
                AntigravityAppBundleIdentity
                    .requiredBundleIdentifier
        )
        let identity = AntigravityVerifiedProcessIdentity(
            processID: 5_103,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 103,
                microseconds: 0
            )!,
            executable: AntigravityCanonicalExecutable(
                canonicalURL: URL(
                    fileURLWithPath:
                        "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
                ),
                role: .appLanguageServer,
                appBundle: bundle
            )
        )!

        await registry.register(identity)

        let ownership = await registry.ownership(for: identity)
        XCTAssertEqual(ownership, .external)
    }

    func testFreshRegistryQuarantinesCurrentBootLedgerProcess()
        async throws
    {
        let directoryURL =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ClaudeUsage-Registry-\(UUID().uuidString)",
                    isDirectory: true
                )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(
                at: directoryURL
            )
        }
        let store = AntigravityManagedProcessRecordFileStore(
            fileURL: directoryURL.appendingPathComponent(
                "managed-agy-sessions.json"
            )
        )
        let boot = AntigravityBootSessionID(
            rawValue: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000901"
            )!
        )
        let verified = makeIdentity(
            processID: 5_105,
            startedAtSeconds: 105
        )
        let owner = try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: 5_005,
                effectiveUserID: 501,
                realUserID: 501,
                startedAtSeconds: 100,
                startedAtMicroseconds: 0,
                executablePath:
                    "/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage",
                kernelIdentity: XCTUnwrap(
                    AntigravityKernelProcessIdentity(
                        uniqueID: 95_005,
                        parentUniqueID: 94_000,
                        pidVersion: 15_005
                    )
                )
            )
        )
        let child = try XCTUnwrap(
            AntigravityRecordedProcessIdentity(
                pid: verified.processID,
                effectiveUserID:
                    verified.effectiveUserID.rawValue,
                realUserID: verified.realUserID.rawValue,
                startedAtSeconds:
                    verified.startedAt.seconds,
                startedAtMicroseconds:
                    verified.startedAt.microseconds,
                executablePath:
                    verified.executable.canonicalURL.path,
                kernelIdentity: XCTUnwrap(
                    AntigravityKernelProcessIdentity(
                        uniqueID: 95_105,
                        parentUniqueID:
                            owner.kernelIdentity.uniqueID,
                        pidVersion: 15_105
                    )
                )
            )
        )
        let intent = try XCTUnwrap(
            AntigravityManagedLaunchIntent(
                sessionID: UUID(),
                bootSessionID: boot,
                owner: owner,
                executable: XCTUnwrap(
                    AntigravityManagedExecutableDescriptor(
                        role: .agyCLI,
                        canonicalPath:
                            verified.executable.canonicalURL.path
                    )
                ),
                createdAt: Date(
                    timeIntervalSince1970: 105
                )
            )
        )
        let record = try XCTUnwrap(
            AntigravityManagedProcessRecord(
                sessionID: intent.sessionID,
                bootSessionID: boot,
                child: child,
                processGroupID: child.pid,
                owner: owner,
                observationCompleteness: .complete,
                createdAt: intent.createdAt
            )
        )
        try store.createIntent(intent)
        try store.promoteIntent(intent, to: record)

        let freshRegistry =
            AntigravityManagedRuntimeRegistry(
                ledgerStore: store,
                bootSessionProvider:
                    RegistryBootSessionProvider(value: boot),
                identityProvider:
                    RegistryIdentityProvider(
                        identity: child
                    )
            )

        let ownership = await freshRegistry.ownership(
            for: verified
        )
        XCTAssertEqual(ownership, .quarantined)
    }

    private func makeIdentity(
        processID: Int32,
        startedAtSeconds: Int64
    ) -> AntigravityVerifiedProcessIdentity {
        AntigravityVerifiedProcessIdentity(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: startedAtSeconds,
                microseconds: 0
            )!,
            executable: AntigravityCanonicalExecutable(
                canonicalURL: URL(
                    fileURLWithPath: "/usr/local/bin/agy"
                ),
                role: .agyCLI
            )
        )!
    }
}

private nonisolated struct RegistryBootSessionProvider:
    AntigravityBootSessionIdentityProviding
{
    let value: AntigravityBootSessionID

    func currentBootSessionID()
        -> AntigravityBootSessionID?
    {
        value
    }
}

private nonisolated struct RegistryIdentityProvider:
    AntigravityManagedProcessIdentityProviding
{
    let identity: AntigravityRecordedProcessIdentity

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        processID == identity.pid ? identity : nil
    }

    func processGroupID(for processID: Int32) -> Int32? {
        processID == identity.pid ? identity.pid : nil
    }
}
