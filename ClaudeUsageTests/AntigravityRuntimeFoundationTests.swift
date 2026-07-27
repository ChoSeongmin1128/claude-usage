import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeFoundationTests: XCTestCase {
    func testPortRejectsZeroAndOutOfRangeValues() {
        XCTAssertNil(AntigravityTCPPort(0))
        XCTAssertNil(AntigravityTCPPort(-1))
        XCTAssertNil(AntigravityTCPPort(65_536))
        XCTAssertNil(AntigravityTCPPort(rawValue: 0))
        XCTAssertEqual(AntigravityTCPPort(65_535)?.rawValue, 65_535)
    }

    func testDesktopLanguageServerRequiresAppOwnership() throws {
        let bundle = AntigravityAppBundleIdentity(
            canonicalRootURL: URL(fileURLWithPath: "/Applications/Antigravity.app"),
            bundleIdentifier: AntigravityAppBundleIdentity.requiredBundleIdentifier
        )
        let executable = AntigravityCanonicalExecutable(
            canonicalURL: bundle.canonicalRootURL
                .appendingPathComponent("Contents/Resources/bin/language_server"),
            role: .appLanguageServer,
            appBundle: bundle
        )
        let startedAt = try XCTUnwrap(AntigravityProcessStartTime(
            seconds: 1_700_000_000,
            microseconds: 123
        ))
        let processIdentity = try XCTUnwrap(AntigravityVerifiedProcessIdentity(
            processID: 10,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: startedAt,
            executable: executable
        ))

        XCTAssertNil(AntigravityRuntimeProcessCandidate(
            processIdentity: processIdentity,
            ownership: .borrowed
        ))
        XCTAssertNotNil(AntigravityRuntimeProcessCandidate(
            processIdentity: processIdentity,
            ownership: .external
        ))
        XCTAssertNil(AntigravityRuntimeProcessCandidate(
            processIdentity: processIdentity,
            ownership: .managed
        ))
    }

    func testVerifiedEndpointEnforcesTransportAuthenticationContract() throws {
        let appBundle = AntigravityAppBundleIdentity(
            canonicalRootURL: URL(fileURLWithPath: "/Applications/Antigravity.app"),
            bundleIdentifier: AntigravityAppBundleIdentity.requiredBundleIdentifier
        )
        let appExecutable = AntigravityCanonicalExecutable(
            canonicalURL: appBundle.canonicalRootURL
                .appendingPathComponent("Contents/Resources/bin/language_server"),
            role: .appLanguageServer,
            appBundle: appBundle
        )
        let agyExecutable = AntigravityCanonicalExecutable(
            canonicalURL: URL(fileURLWithPath: "/Users/test/.local/bin/agy"),
            role: .agyCLI
        )
        let appProcess = try makeVerifiedProcess(executable: appExecutable)
        let agyProcess = try makeVerifiedProcess(executable: agyExecutable)
        let port = try XCTUnwrap(AntigravityTCPPort(54_321))
        let token = try XCTUnwrap(AntigravityCSRFToken("token"))

        XCTAssertNotNil(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: appProcess,
            host: .ipv4,
            port: port,
            transport: .antigravityApp,
            ownership: .external,
            authentication: .appCSRF(token)
        ))
        XCTAssertNil(AntigravityCSRFToken("  "))
        XCTAssertEqual(String(describing: token), "<redacted>")
        XCTAssertFalse(
            String(describing: AntigravityRuntimeConnectionHints(
                requestedPort: port,
                csrfToken: token
            )).contains(token.value)
        )
        XCTAssertNil(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: appProcess,
            host: .ipv4,
            port: port,
            transport: .antigravityApp,
            ownership: .external,
            authentication: .cliTokenless
        ))
        XCTAssertNotNil(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: agyProcess,
            host: .ipv4,
            port: port,
            transport: .agyCLI,
            ownership: .borrowed,
            authentication: .cliTokenless
        ))
        XCTAssertNil(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: agyProcess,
            host: .ipv6,
            port: port,
            transport: .agyCLI,
            ownership: .borrowed,
            authentication: .cliTokenless
        ))
        XCTAssertNil(AntigravityVerifiedRuntimeEndpoint(
            processIdentity: agyProcess,
            host: .ipv4,
            port: port,
            transport: .agyCLI,
            ownership: .borrowed,
            authentication: .appCSRF(token)
        ))

        XCTAssertNotNil(AntigravityRuntimeProcessCandidate(
            processIdentity: agyProcess,
            ownership: .borrowed
        ))
        XCTAssertNotNil(AntigravityRuntimeProcessCandidate(
            processIdentity: agyProcess,
            ownership: .managed
        ))
        XCTAssertNil(AntigravityRuntimeProcessCandidate(
            processIdentity: agyProcess,
            ownership: .external
        ))
    }

    func testDeadlineCapsDiscoveryAtTwoSecondsAndPreservesTotalBudget() throws {
        let clock = TestMonotonicClock()
        let deadline = AntigravityRPCDeadline(
            startedAt: clock.now,
            totalTimeout: .seconds(8),
            discoveryTimeout: .seconds(9),
            now: { clock.now }
        )

        XCTAssertEqual(
            try deadline.timeout(for: .discovery),
            .seconds(2)
        )
        clock.advance(by: .milliseconds(1_500))
        XCTAssertEqual(
            try deadline.timeout(for: .discovery),
            .milliseconds(500)
        )
        XCTAssertEqual(
            try deadline.timeout(for: .request),
            .milliseconds(6_500)
        )
    }

    func testExpiredDiscoveryDoesNotResetTotalDeadline() throws {
        let clock = TestMonotonicClock()
        let deadline = AntigravityRPCDeadline(
            startedAt: clock.now,
            totalTimeout: .seconds(8),
            discoveryTimeout: .seconds(2),
            now: { clock.now }
        )
        clock.advance(by: .seconds(2))

        XCTAssertThrowsError(try deadline.timeout(for: .discovery)) { error in
            XCTAssertEqual(
                error as? AntigravityRPCDeadlineError,
                .timedOut(.discovery)
            )
        }
        XCTAssertEqual(
            try deadline.timeout(for: .request),
            .seconds(6)
        )
    }

    func testDeadlineRejectsInvalidPerStepMaximum() throws {
        let deadline = AntigravityRPCDeadline()

        XCTAssertThrowsError(
            try deadline.timeout(for: .request, maximum: .zero)
        ) { error in
            XCTAssertEqual(
                error as? AntigravityRPCDeadlineError,
                .invalidTimeout
            )
        }
        XCTAssertThrowsError(
            try deadline.timeInterval(for: .request, maximum: .nan)
        ) { error in
            XCTAssertEqual(
                error as? AntigravityRPCDeadlineError,
                .invalidTimeout
            )
        }
    }

    func testDeadlinePropagatesTaskCancellation() async {
        let deadline = AntigravityRPCDeadline()
        let task = Task { () -> Error? in
            while !Task.isCancelled {
                await Task.yield()
            }
            do {
                try deadline.check(.request)
                return nil
            } catch {
                return error
            }
        }
        task.cancel()

        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }

    func testCatalogRequiresExactBundleIdentifierAndRelativePath() throws {
        let fileSystem = CatalogFileSystemStub()
        let acceptedRoot = URL(fileURLWithPath: "/Applications/Antigravity.app")
        let wrongRoot = URL(fileURLWithPath: "/Applications/Fake.app")
        fileSystem.bundleIdentifiers[acceptedRoot.path] =
            AntigravityAppBundleIdentity.requiredBundleIdentifier
        fileSystem.bundleIdentifiers[wrongRoot.path] = "example.fake"

        let accepted = acceptedRoot
            .appendingPathComponent("Contents/Resources/bin/language_server")
        let prefixOnly = acceptedRoot
            .appendingPathComponent("Contents/Resources/bin/language_server_future")
        let wrongBundleExecutable = wrongRoot
            .appendingPathComponent("Contents/Resources/bin/language_server")
        fileSystem.executablePaths = [
            accepted.path,
            prefixOnly.path,
            wrongBundleExecutable.path,
        ]

        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [acceptedRoot, wrongRoot],
            agyExecutableURLs: [],
            fileSystem: fileSystem
        )

        XCTAssertEqual(catalog.appBundles.map(\.canonicalRootURL), [acceptedRoot])
        XCTAssertEqual(catalog.executables.map(\.canonicalURL), [accepted])
        XCTAssertNotNil(catalog.executable(matching: accepted))
        XCTAssertNil(catalog.executable(matching: prefixOnly))
        XCTAssertNil(catalog.executable(matching: wrongBundleExecutable))
    }

    func testCatalogMatchesOnlyExplicitCanonicalAGYEntries() throws {
        let fileSystem = CatalogFileSystemStub()
        let configured = URL(fileURLWithPath: "/usr/local/bin/agy")
        let canonical = URL(fileURLWithPath: "/opt/tools/agy")
        let unrelated = URL(fileURLWithPath: "/tmp/agy")
        fileSystem.canonicalPaths[configured.path] = canonical
        fileSystem.executablePaths = [canonical.path, unrelated.path]

        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [],
            agyExecutableURLs: [configured],
            fileSystem: fileSystem
        )

        XCTAssertEqual(catalog.executables.map(\.canonicalURL), [canonical])
        XCTAssertEqual(catalog.executable(matching: configured)?.canonicalURL, canonical)
        XCTAssertEqual(catalog.executable(matching: canonical)?.canonicalURL, canonical)
        XCTAssertNil(catalog.executable(matching: unrelated))
    }

    func testCatalogRejectsLanguageServerSymlinkLeavingVerifiedBundle() throws {
        let fileSystem = CatalogFileSystemStub()
        let root = URL(fileURLWithPath: "/Applications/Antigravity.app")
        let expected = root
            .appendingPathComponent("Contents/Resources/bin/language_server")
        let redirected = URL(fileURLWithPath: "/tmp/language_server")
        fileSystem.bundleIdentifiers[root.path] =
            AntigravityAppBundleIdentity.requiredBundleIdentifier
        fileSystem.canonicalPaths[expected.path] = redirected
        fileSystem.executablePaths = [redirected.path]

        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [root],
            agyExecutableURLs: [],
            fileSystem: fileSystem
        )

        XCTAssertTrue(catalog.executables.isEmpty)
    }

    func testCatalogEnumeratesOnlyExplicitLegacyLanguageServerPaths() {
        let fileSystem = CatalogFileSystemStub()
        let root = URL(fileURLWithPath: "/Applications/Antigravity.app")
        fileSystem.bundleIdentifiers[root.path] =
            AntigravityAppBundleIdentity.requiredBundleIdentifier
        let expected = AntigravityExecutableCatalog.appLanguageServerRelativePaths
            .map { root.appendingPathComponent($0).path }
        fileSystem.executablePaths = Set(expected + [
            root.appendingPathComponent(
                "Contents/Resources/bin/language_server_macos_future"
            ).path,
            root.appendingPathComponent(
                "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm"
            ).path,
        ])

        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: [root],
            agyExecutableURLs: [],
            fileSystem: fileSystem
        )

        XCTAssertEqual(
            Set(catalog.executables.map(\.canonicalURL.path)),
            Set(expected)
        )
    }
}

private func makeVerifiedProcess(
    executable: AntigravityCanonicalExecutable
) throws -> AntigravityVerifiedProcessIdentity {
    let startedAt = try XCTUnwrap(AntigravityProcessStartTime(
        seconds: 1_700_000_000,
        microseconds: 0
    ))
    return try XCTUnwrap(AntigravityVerifiedProcessIdentity(
        processID: 42,
        effectiveUserID: AntigravityUserID(rawValue: 501),
        realUserID: AntigravityUserID(rawValue: 501),
        startedAt: startedAt,
        executable: executable
    ))
}

private final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            instant = instant.advanced(by: duration)
        }
    }
}

private final class CatalogFileSystemStub:
    AntigravityExecutableCatalogFileSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    var bundleIdentifiers: [String: String] = [:]
    var canonicalPaths: [String: URL] = [:]
    var executablePaths: Set<String> = []

    func canonicalURL(for url: URL) -> URL {
        lock.withLock {
            canonicalPaths[url.path] ?? url.standardizedFileURL
        }
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        lock.withLock {
            executablePaths.contains(url.path)
        }
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        lock.withLock {
            bundleIdentifiers[appBundleRoot.path]
        }
    }
}
