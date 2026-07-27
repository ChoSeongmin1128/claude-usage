import Foundation
import XCTest
@testable import ClaudeUsage

final class
    AntigravityProductionExecutableCatalogResolverTests:
    XCTestCase
{
    private let home = URL(
        fileURLWithPath: "/Users/example",
        isDirectory: true
    )

    func testProductionCandidatesAreFixedAndDeterministic() {
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )

        XCTAssertEqual(
            candidates.appBundleRoots.map(\.path),
            [
                "/Applications/Antigravity.app",
                "/Users/example/Applications/Antigravity.app",
            ]
        )
        XCTAssertEqual(
            candidates.agyExecutableURLs.map(\.path),
            [
                "/Users/example/.local/bin/agy",
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
            ]
        )
        XCTAssertFalse(
            candidates.agyExecutableURLs.contains {
                $0.path == "/tmp/agy"
                    || $0.lastPathComponent != "agy"
            }
        )
    }

    func testVerifiedCandidatesPopulateCatalogAndUseFixedPriority() {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let systemApp = candidates.appBundleRoots[0]
        let userApp = candidates.appBundleRoots[1]
        let systemLanguageServer = systemApp
            .appendingPathComponent(
                AntigravityExecutableCatalog
                    .appLanguageServerRelativePaths[0]
            )
        let userLanguageServer = userApp
            .appendingPathComponent(
                AntigravityExecutableCatalog
                    .appLanguageServerRelativePaths[0]
            )

        for app in [systemApp, userApp] {
            fileSystem.directories.insert(app.path)
            fileSystem.bundleIdentifiers[app.path] =
                AntigravityOfficialExecutableTrustPolicy
                    .appSigningIdentifier
            trust.identities[app.path] = .officialApp
        }
        for executable in [
            systemLanguageServer,
            userLanguageServer,
        ] {
            fileSystem.regularExecutables.insert(executable.path)
        }
        for executable in candidates.agyExecutableURLs {
            fileSystem.regularExecutables.insert(executable.path)
            fileSystem.machOExecutables.insert(executable.path)
            fileSystem.secureExecutables.insert(executable.path)
        }
        let fileIdentity = StubFileIdentityInspector(
            officialURLs: candidates.agyExecutableURLs
        )
        fileIdentity.identities[systemLanguageServer.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: String(repeating: "a", count: 64),
                inode: 101
            )
        fileIdentity.identities[userLanguageServer.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: String(repeating: "b", count: 64),
                inode: 102
            )

        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()

        XCTAssertEqual(
            resolution.catalog.appBundles.map {
                $0.canonicalRootURL.path
            },
            [systemApp.path, userApp.path]
        )
        XCTAssertEqual(
            resolution.catalog.executables.filter {
                $0.role == .agyCLI
            }.count,
            3
        )
        XCTAssertEqual(
            resolution.catalog.executables.filter {
                $0.role == .appLanguageServer
            }.count,
            2
        )
        XCTAssertEqual(
            resolution.managedLaunchExecutable?.canonicalURL.path,
            candidates.agyExecutableURLs[0].path
        )
    }

    func testPinnedOfficialBytesCanLaunchWhenStaticSignatureIsInvalid()
        throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )

        for executable in candidates.agyExecutableURLs {
            fileSystem.regularExecutables.insert(executable.path)
            fileSystem.machOExecutables.insert(executable.path)
            fileSystem.secureExecutables.insert(executable.path)
        }
        trust.identities[candidates.agyExecutableURLs[0].path] =
            AntigravityCodeSignatureIdentity(
                signingIdentifier: "cli",
                teamIdentifier: "WRONGTEAM"
            )
        // The second candidate is intentionally unsigned: no identity.
        trust.identities[candidates.agyExecutableURLs[2].path] =
            AntigravityCodeSignatureIdentity(
                signingIdentifier: "not-the-official-cli",
                teamIdentifier:
                    AntigravityOfficialExecutableTrustPolicy
                        .teamIdentifier
            )

        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: StubFileIdentityInspector(
                officialURLs: candidates.agyExecutableURLs
            )
        ).resolve()

        XCTAssertEqual(
            resolution.catalog.executables.filter {
                $0.role == .agyCLI
            }.count,
            3
        )
        let managedExecutable = try XCTUnwrap(
            resolution.managedLaunchExecutable
        )
        let managedFileIdentity = try XCTUnwrap(
            managedExecutable.fileIdentity
        )
        XCTAssertEqual(
            managedExecutable.canonicalURL.path,
            candidates.agyExecutableURLs[0].path
        )
        XCTAssertTrue(
            AntigravityOfficialAGYBinaryDigestPolicy.accepts(
                managedFileIdentity.sha256Digest
            )
        )
    }

    func testAppRequiresExactBundleAndSigningIdentity() {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let wrongBundleApp = candidates.appBundleRoots[0]
        let wrongSignatureApp = candidates.appBundleRoots[1]

        for app in [wrongBundleApp, wrongSignatureApp] {
            fileSystem.directories.insert(app.path)
        }
        fileSystem.bundleIdentifiers[wrongBundleApp.path] =
            "com.example.lookalike"
        trust.identities[wrongBundleApp.path] = .officialApp
        fileSystem.bundleIdentifiers[wrongSignatureApp.path] =
            AntigravityOfficialExecutableTrustPolicy
                .appSigningIdentifier
        trust.identities[wrongSignatureApp.path] =
            AntigravityCodeSignatureIdentity(
                signingIdentifier: "com.example.lookalike",
                teamIdentifier:
                    AntigravityOfficialExecutableTrustPolicy
                        .teamIdentifier
            )

        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust
        ).resolve()

        XCTAssertTrue(resolution.catalog.appBundles.isEmpty)
        XCTAssertTrue(resolution.catalog.executables.isEmpty)
    }

    func testSymlinkWrapperAndUnlistedPathsAreRejected() {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let symlink = candidates.agyExecutableURLs[0]
        let wrapper = candidates.agyExecutableURLs[1]
        let absent = candidates.agyExecutableURLs[2]
        let unlisted = URL(fileURLWithPath: "/tmp/agy")
        let wrongName = home
            .appendingPathComponent(".local/bin/not-agy")

        fileSystem.symbolicLinks.insert(symlink.path)
        fileSystem.canonicalURLs[symlink.path] =
            URL(fileURLWithPath: "/private/opt/agy")
        fileSystem.regularExecutables.insert(symlink.path)
        fileSystem.machOExecutables.insert(symlink.path)
        fileSystem.secureExecutables.insert(symlink.path)

        fileSystem.regularExecutables.insert(wrapper.path)
        fileSystem.secureExecutables.insert(wrapper.path)
        // No Mach-O header: an executable shell wrapper must not be trusted.

        for executable in [unlisted, wrongName] {
            fileSystem.regularExecutables.insert(executable.path)
            fileSystem.machOExecutables.insert(executable.path)
            fileSystem.secureExecutables.insert(executable.path)
        }

        XCTAssertFalse(
            fileSystem.regularExecutables.contains(absent.path)
        )
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: StubFileIdentityInspector(
                officialURLs: [
                    symlink,
                    wrapper,
                    unlisted,
                    wrongName,
                ]
            )
        ).resolve()

        XCTAssertTrue(resolution.catalog.executables.isEmpty)
        XCTAssertNil(resolution.managedLaunchExecutable)
    }

    func testInsecureOwnershipOrPermissionsRejectDiscovery() {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let insecure = candidates.agyExecutableURLs[0]

        fileSystem.regularExecutables.insert(insecure.path)
        fileSystem.machOExecutables.insert(insecure.path)

        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: StubFileIdentityInspector(
                officialURLs: [insecure]
            )
        ).resolve()

        XCTAssertTrue(resolution.catalog.executables.isEmpty)
        XCTAssertNil(resolution.managedLaunchExecutable)
    }

    func testUnknownBinaryDigestRejectsDiscovery() {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let unknown = candidates.agyExecutableURLs[0]

        fileSystem.regularExecutables.insert(unknown.path)
        fileSystem.machOExecutables.insert(unknown.path)
        fileSystem.secureExecutables.insert(unknown.path)
        let fileIdentity = StubFileIdentityInspector()
        fileIdentity.identities[unknown.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: String(repeating: "0", count: 64),
                inode: 99
            )

        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()

        XCTAssertTrue(resolution.catalog.executables.isEmpty)
        XCTAssertNil(resolution.managedLaunchExecutable)
    }

    func testPostCatalogSamePathReplacementRejectsBorrowedProcess()
        async throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let executableURL = candidates.agyExecutableURLs[0]
        fileSystem.regularExecutables.insert(executableURL.path)
        fileSystem.machOExecutables.insert(executableURL.path)
        fileSystem.secureExecutables.insert(executableURL.path)
        let fileIdentity = StubFileIdentityInspector(
            officialURLs: [executableURL]
        )
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()
        let executable = try XCTUnwrap(
            resolution.managedLaunchExecutable
        )
        let resolvedIdentity = try XCTUnwrap(
            executable.fileIdentity
        )

        // Simulate an atomic rename of identical reviewed bytes. A digest-only
        // recheck would accept this; the changed vnode identity must not.
        fileIdentity.identities[executableURL.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: resolvedIdentity.sha256Digest,
                inode: resolvedIdentity.inode + 1
            )
        let processID: Int32 = 8_401
        let processInfo = AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 1_700_000_000,
                microseconds: 321
            )!
        )
        let inspector = AntigravityProcessInspector(
            catalog: resolution.catalog,
            subprocessRunner: StubProcessListRunner(
                output: "\(processID) \(executableURL.path) --port=54321"
            ),
            libprocReader: StubLibprocReader(
                processInfo: processInfo,
                executableURL: executableURL
            ),
            kernelIdentityReader: StubKernelIdentityReader(),
            runningExecutableImageValidator:
                StubRunningImageValidator(result: true),
            runningCodeTrustValidator:
                StubRunningCodeTrustValidator(result: true),
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID
        )

        let processes = try await inspector.discoverProcesses(
            timeout: 1
        )

        XCTAssertTrue(processes.isEmpty)
    }

    func testPostCatalogAppLanguageServerReplacementIsRejected()
        async throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let appRoot = candidates.appBundleRoots[0]
        let executableURL = appRoot.appendingPathComponent(
            AntigravityExecutableCatalog
                .appLanguageServerRelativePaths[0]
        )
        fileSystem.directories.insert(appRoot.path)
        fileSystem.bundleIdentifiers[appRoot.path] =
            AntigravityAppBundleIdentity
                .requiredBundleIdentifier
        fileSystem.regularExecutables.insert(executableURL.path)
        trust.identities[appRoot.path] = .officialApp
        let fileIdentity = StubFileIdentityInspector()
        let startupIdentity =
            StubFileIdentityInspector.makeIdentity(
                digest: String(repeating: "c", count: 64),
                inode: 201
            )
        fileIdentity.identities[executableURL.path] =
            startupIdentity
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()
        let executable = try XCTUnwrap(
            resolution.catalog.executables.first {
                $0.role == .appLanguageServer
            }
        )
        XCTAssertEqual(executable.fileIdentity, startupIdentity)

        fileIdentity.identities[executableURL.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: startupIdentity.sha256Digest,
                inode: startupIdentity.inode + 1
            )
        let processID: Int32 = 8_402
        let processInfo = AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 1_700_000_001,
                microseconds: 322
            )!
        )
        let inspector = AntigravityProcessInspector(
            catalog: resolution.catalog,
            subprocessRunner: StubProcessListRunner(
                output:
                    "\(processID) \(executableURL.path) --https_server_port=54321 --csrf_token=test"
            ),
            libprocReader: StubLibprocReader(
                processInfo: processInfo,
                executableURL: executableURL
            ),
            kernelIdentityReader: StubKernelIdentityReader(),
            runningExecutableImageValidator:
                StubRunningImageValidator(result: true),
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID
        )

        let processes = try await inspector.discoverProcesses(
            timeout: 1
        )

        XCTAssertTrue(processes.isEmpty)
    }

    func testAppLanguageServerRejectsUntrustedRunningCodeAfterPathRestored()
        async throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let appRoot = candidates.appBundleRoots[0]
        let executableURL = appRoot.appendingPathComponent(
            AntigravityExecutableCatalog
                .appLanguageServerRelativePaths[0]
        )
        fileSystem.directories.insert(appRoot.path)
        fileSystem.bundleIdentifiers[appRoot.path] =
            AntigravityAppBundleIdentity
                .requiredBundleIdentifier
        fileSystem.regularExecutables.insert(executableURL.path)
        trust.identities[appRoot.path] = .officialApp
        let fileIdentity = StubFileIdentityInspector()
        fileIdentity.identities[executableURL.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: String(repeating: "d", count: 64),
                inode: 301
            )
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()
        let executable = try XCTUnwrap(
            resolution.catalog.executables.first {
                $0.role == .appLanguageServer
            }
        )
        XCTAssertTrue(resolution.catalog.isCurrent(executable))

        let processID: Int32 = 8_404
        let processInfo = AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 1_700_000_003,
                microseconds: 324
            )!
        )
        let inspector = AntigravityProcessInspector(
            catalog: resolution.catalog,
            subprocessRunner: StubProcessListRunner(
                output:
                    "\(processID) \(executableURL.path) --https_server_port=54321 --csrf_token=test"
            ),
            libprocReader: StubLibprocReader(
                processInfo: processInfo,
                executableURL: executableURL
            ),
            kernelIdentityReader: StubKernelIdentityReader(),
            runningExecutableImageValidator:
                StubRunningImageValidator(result: true),
            runningCodeTrustValidator:
                StubRunningCodeTrustValidator(result: false),
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID
        )

        let processes = try await inspector.discoverProcesses(
            timeout: 1
        )

        XCTAssertTrue(processes.isEmpty)
    }

    func testBorrowedProcessRejectsMismatchedRunningImageAfterPathRestored()
        async throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let executableURL = candidates.agyExecutableURLs[0]
        fileSystem.regularExecutables.insert(executableURL.path)
        fileSystem.machOExecutables.insert(executableURL.path)
        fileSystem.secureExecutables.insert(executableURL.path)
        let fileIdentity = StubFileIdentityInspector(
            officialURLs: [executableURL]
        )
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()
        let executable = try XCTUnwrap(
            resolution.managedLaunchExecutable
        )
        XCTAssertTrue(resolution.catalog.isCurrent(executable))

        let processID: Int32 = 8_403
        let processInfo = AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: 501),
            realUserID: AntigravityUserID(rawValue: 501),
            startedAt: AntigravityProcessStartTime(
                seconds: 1_700_000_002,
                microseconds: 323
            )!
        )
        let inspector = AntigravityProcessInspector(
            catalog: resolution.catalog,
            subprocessRunner: StubProcessListRunner(
                output:
                    "\(processID) \(executableURL.path) --port=54321"
            ),
            libprocReader: StubLibprocReader(
                processInfo: processInfo,
                executableURL: executableURL
            ),
            kernelIdentityReader: StubKernelIdentityReader(),
            runningExecutableImageValidator:
                StubRunningImageValidator(result: false),
            effectiveUserID: processInfo.effectiveUserID,
            realUserID: processInfo.realUserID
        )

        let processes = try await inspector.discoverProcesses(
            timeout: 1
        )

        XCTAssertTrue(processes.isEmpty)
    }

    func testPostCatalogSamePathReplacementRejectsManagedSpawn()
        throws
    {
        let fileSystem = StubResolverFileSystem()
        let trust = StubTrustInspector()
        let candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: home
        )
        let executableURL = candidates.agyExecutableURLs[0]
        fileSystem.regularExecutables.insert(executableURL.path)
        fileSystem.machOExecutables.insert(executableURL.path)
        fileSystem.secureExecutables.insert(executableURL.path)
        let fileIdentity = StubFileIdentityInspector(
            officialURLs: [executableURL]
        )
        let resolution = makeResolver(
            fileSystem: fileSystem,
            trust: trust,
            fileIdentity: fileIdentity
        ).resolve()
        let executable = try XCTUnwrap(
            resolution.managedLaunchExecutable
        )
        let resolvedIdentity = try XCTUnwrap(
            executable.fileIdentity
        )
        fileIdentity.identities[executableURL.path] =
            StubFileIdentityInspector.makeIdentity(
                digest: resolvedIdentity.sha256Digest,
                inode: resolvedIdentity.inode + 1
            )
        let request = try XCTUnwrap(
            AntigravityManagedCLIProcessLaunchRequest(
                executable: executable,
                environment: AntigravityManagedCLIEnvironment(
                    homeDirectory: home,
                    userName: "example"
                ),
                currentDirectoryURL: home
            )
        )

        XCTAssertThrowsError(
            try AntigravityManagedCLIProcessLauncher(
                executableRevalidator: resolution.catalog
            ).launchSuspended(request)
        ) {
            XCTAssertEqual(
                $0 as? AntigravityManagedSessionError,
                .executableNotAllowed
            )
        }
    }

    func testEmptyResolutionRemainsAValidCompositionInput() {
        let resolution = makeResolver(
            fileSystem: StubResolverFileSystem(),
            trust: StubTrustInspector()
        ).resolve()

        XCTAssertTrue(resolution.catalog.appBundles.isEmpty)
        XCTAssertTrue(resolution.catalog.executables.isEmpty)
        XCTAssertNil(resolution.managedLaunchExecutable)
    }

    private func makeResolver(
        fileSystem: StubResolverFileSystem,
        trust: StubTrustInspector,
        fileIdentity:
            StubFileIdentityInspector =
                StubFileIdentityInspector()
    ) -> AntigravityProductionExecutableCatalogResolver {
        AntigravityProductionExecutableCatalogResolver(
            homeDirectoryURL: home,
            fileSystem: fileSystem,
            trustInspector: trust,
            fileIdentityInspector: fileIdentity
        )
    }
}

private struct StubRunningImageValidator:
    AntigravityRunningExecutableImageValidating
{
    let result: Bool

    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        result
    }
}

private struct StubRunningCodeTrustValidator:
    AntigravityRunningCodeTrustValidating
{
    let result: Bool

    func validatesRunningCode(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        result
    }
}

private struct StubKernelIdentityReader:
    AntigravityKernelProcessIdentityReading
{
    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        AntigravityKernelProcessIdentity(
            uniqueID: UInt64(processID),
            parentUniqueID: 1,
            pidVersion: 1
        )
    }
}

private struct StubProcessListRunner:
    AntigravityOwnedSubprocessRunning
{
    let output: String

    func run(
        _ request: AntigravityOwnedSubprocessRequest
    ) async throws -> AntigravityOwnedSubprocessResult {
        AntigravityOwnedSubprocessResult(
            standardOutput: Data(output.utf8),
            standardError: Data(),
            terminationStatus: 0
        )
    }
}

private struct StubLibprocReader: AntigravityLibprocReading {
    let processInfo: AntigravityBSDProcessInfo
    let executableURL: URL

    func bsdInfo(
        for processID: Int32
    ) -> AntigravityBSDProcessInfo? {
        processID == processInfo.processID
            ? processInfo
            : nil
    }

    func executableURL(for processID: Int32) -> URL? {
        processID == processInfo.processID
            ? executableURL
            : nil
    }
}

private final class StubResolverFileSystem:
    AntigravityProductionExecutableResolverFileSystem,
    @unchecked Sendable
{
    var canonicalURLs: [String: URL] = [:]
    var regularExecutables: Set<String> = []
    var directories: Set<String> = []
    var symbolicLinks: Set<String> = []
    var machOExecutables: Set<String> = []
    var secureExecutables: Set<String> = []
    var bundleIdentifiers: [String: String] = [:]

    func canonicalURL(for url: URL) -> URL {
        canonicalURLs[url.path] ?? url.standardizedFileURL
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        regularExecutables.contains(url.path)
            && !symbolicLinks.contains(url.path)
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        bundleIdentifiers[appBundleRoot.path]
    }

    func isDirectory(at url: URL) -> Bool {
        directories.contains(url.path)
    }

    func isSymbolicLink(at url: URL) -> Bool {
        symbolicLinks.contains(url.path)
    }

    func hasMachOHeader(at url: URL) -> Bool {
        machOExecutables.contains(url.path)
    }

    func hasSecureOwnershipAndPermissions(at url: URL) -> Bool {
        secureExecutables.contains(url.path)
    }
}

private final class StubTrustInspector:
    AntigravityExecutableTrustInspecting,
    @unchecked Sendable
{
    var identities:
        [String: AntigravityCodeSignatureIdentity] = [:]

    func validatedIdentity(
        at url: URL
    ) -> AntigravityCodeSignatureIdentity? {
        identities[url.path]
    }
}

private final class StubFileIdentityInspector:
    AntigravityExecutableFileIdentityInspecting,
    @unchecked Sendable
{
    var identities:
        [String: AntigravityExecutableFileIdentity] = [:]

    init(officialURLs: [URL] = []) {
        let officialDigest =
            AntigravityOfficialAGYBinaryDigestPolicy
                .knownSHA256Digests.first!
        for (index, url) in officialURLs.enumerated() {
            identities[url.path] = Self.makeIdentity(
                digest: officialDigest,
                inode: UInt64(index + 1)
            )
        }
    }

    func identity(
        at url: URL
    ) -> AntigravityExecutableFileIdentity? {
        identities[url.path]
    }

    static func makeIdentity(
        digest: String,
        inode: UInt64
    ) -> AntigravityExecutableFileIdentity {
        AntigravityExecutableFileIdentity(
            deviceID: 1,
            inode: inode,
            fileSize: 1_024,
            changeTimeSeconds: 1_700_000_000,
            changeTimeNanoseconds: 123,
            sha256Digest: digest
        )!
    }
}

private extension AntigravityCodeSignatureIdentity {
    static let officialApp =
        AntigravityCodeSignatureIdentity(
            signingIdentifier:
                AntigravityOfficialExecutableTrustPolicy
                    .appSigningIdentifier,
            teamIdentifier:
                AntigravityOfficialExecutableTrustPolicy
                    .teamIdentifier
        )
}
