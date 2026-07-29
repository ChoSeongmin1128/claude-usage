import CryptoKit
import Darwin
import Foundation
import Security

nonisolated struct AntigravityCodeSignatureIdentity:
    Sendable,
    Equatable
{
    let signingIdentifier: String
    let teamIdentifier: String
}

/// Reads and validates a static code signature without executing the candidate.
nonisolated protocol AntigravityExecutableTrustInspecting: Sendable {
    func validatedIdentity(
        at url: URL,
        satisfying requirementSource: String?
    ) -> AntigravityCodeSignatureIdentity?
}

nonisolated extension AntigravityExecutableTrustInspecting {
    func validatedIdentity(
        at url: URL
    ) -> AntigravityCodeSignatureIdentity? {
        validatedIdentity(at: url, satisfying: nil)
    }
}

nonisolated struct AntigravitySystemExecutableTrustInspector:
    AntigravityExecutableTrustInspecting
{
    func validatedIdentity(
        at url: URL,
        satisfying requirementSource: String?
    ) -> AntigravityCodeSignatureIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            return nil
        }

        let validationFlags = SecCSFlags(
            rawValue: UInt32(
                kSecCSCheckAllArchitectures
                    | kSecCSStrictValidate
                    | kSecCSRestrictSymlinks
            )
        )
        let requirement: SecRequirement?
        if let requirementSource {
            var parsed: SecRequirement?
            guard SecRequirementCreateWithString(
                requirementSource as CFString,
                SecCSFlags(),
                &parsed
            ) == errSecSuccess,
            let parsed
            else {
                return nil
            }
            requirement = parsed
        } else {
            requirement = nil
        }

        guard SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            requirement
        ) == errSecSuccess else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any],
        let signingIdentifier =
            values[kSecCodeInfoIdentifier as String] as? String,
        let teamIdentifier =
            values[kSecCodeInfoTeamIdentifier as String] as? String,
        !signingIdentifier.isEmpty,
        !teamIdentifier.isEmpty
        else {
            return nil
        }

        return AntigravityCodeSignatureIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}

nonisolated protocol AntigravityExecutableFileIdentityInspecting:
    Sendable
{
    func identity(
        at url: URL
    ) -> AntigravityExecutableFileIdentity?

    func matches(
        _ expected: AntigravityExecutableFileIdentity,
        at url: URL
    ) -> Bool
}

nonisolated extension
    AntigravityExecutableFileIdentityInspecting
{
    func matches(
        _ expected: AntigravityExecutableFileIdentity,
        at url: URL
    ) -> Bool {
        identity(at: url) == expected
    }
}

nonisolated struct AntigravitySystemExecutableFileIdentityInspector:
    AntigravityExecutableFileIdentityInspecting
{
    func identity(
        at url: URL
    ) -> AntigravityExecutableFileIdentity? {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            return nil
        }
        defer { Darwin.close(descriptor) }

        return identity(ofOpenFileDescriptor: descriptor)
    }

    /// A captured digest remains bound to one vnode as long as immutable
    /// kernel metadata is unchanged. This avoids re-hashing the 150+ MB AGY
    /// binary on every discovery/revalidation while still detecting atomic
    /// replacement, writes, chmod/chown, and hard-link changes.
    func matches(
        _ expected: AntigravityExecutableFileIdentity,
        at url: URL
    ) -> Bool {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        return fstat(descriptor, &status) == 0
            && Self.isExecutableRegularFile(status)
            && Self.metadata(
                status,
                matches: expected
            )
    }

    /// The caller retains ownership of `descriptor`.
    func identity(
        ofOpenFileDescriptor descriptor: Int32
    ) -> AntigravityExecutableFileIdentity? {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              Self.isExecutableRegularFile(before),
              before.st_size >= 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var hasher = SHA256()
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count > 0 {
                hasher.update(
                    data: Data(buffer.prefix(Int(count)))
                )
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            return nil
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              Self.sameFile(before, after) else {
            return nil
        }

        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return AntigravityExecutableFileIdentity(
            deviceID: UInt64(bitPattern: Int64(before.st_dev)),
            inode: UInt64(before.st_ino),
            fileSize: UInt64(before.st_size),
            changeTimeSeconds:
                Int64(before.st_ctimespec.tv_sec),
            changeTimeNanoseconds:
                Int64(before.st_ctimespec.tv_nsec),
            sha256Digest: digest
        )
    }

    private static func isExecutableRegularFile(
        _ status: stat
    ) -> Bool {
        let ownerIsTrusted =
            status.st_uid == geteuid()
                || status.st_uid == 0
        return (status.st_mode & mode_t(S_IFMT))
                == mode_t(S_IFREG)
            && (status.st_mode & mode_t(0o111)) != 0
            && ownerIsTrusted
            && (status.st_mode & mode_t(0o022)) == 0
            && status.st_nlink == 1
    }

    private static func sameFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }

    private static func metadata(
        _ status: stat,
        matches expected: AntigravityExecutableFileIdentity
    ) -> Bool {
        status.st_size >= 0
            && UInt64(bitPattern: Int64(status.st_dev))
                == expected.deviceID
            && UInt64(status.st_ino) == expected.inode
            && UInt64(status.st_size) == expected.fileSize
            && Int64(status.st_ctimespec.tv_sec)
                == expected.changeTimeSeconds
            && Int64(status.st_ctimespec.tv_nsec)
                == expected.changeTimeNanoseconds
    }
}

nonisolated protocol
    AntigravityProductionExecutableResolverFileSystem:
    AntigravityExecutableCatalogFileSystem
{
    func itemExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func isSymbolicLink(at url: URL) -> Bool
    func hasMachOHeader(at url: URL) -> Bool
    func hasSecureOwnershipAndPermissions(at url: URL) -> Bool
}

nonisolated struct
    AntigravitySystemProductionExecutableResolverFileSystem:
    AntigravityProductionExecutableResolverFileSystem
{
    func itemExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    func canonicalURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        AntigravitySystemExecutableCatalogFileSystem()
            .isExecutableRegularFile(at: url)
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        Bundle(url: appBundleRoot)?.bundleIdentifier
    }

    func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) == true
    }

    func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) == true
    }

    func hasMachOHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer {
            try? handle.close()
        }
        guard let data = try? handle.read(upToCount: 4),
              data.count == 4
        else {
            return false
        }

        let bytes = Array(data)
        return Self.machOMagicHeaders.contains(bytes)
    }

    func hasSecureOwnershipAndPermissions(at url: URL) -> Bool {
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            return false
        }

        let ownerIsTrusted =
            fileStatus.st_uid == geteuid()
                || fileStatus.st_uid == 0
        let isNotGroupOrWorldWritable =
            (fileStatus.st_mode & mode_t(0o022)) == 0
        let hasSingleHardLink = fileStatus.st_nlink == 1

        return ownerIsTrusted
            && isNotGroupOrWorldWritable
            && hasSingleHardLink
    }

    private static let machOMagicHeaders: Set<[UInt8]> = [
        [0xCE, 0xFA, 0xED, 0xFE],
        [0xCF, 0xFA, 0xED, 0xFE],
        [0xFE, 0xED, 0xFA, 0xCE],
        [0xFE, 0xED, 0xFA, 0xCF],
        [0xCA, 0xFE, 0xBA, 0xBE],
        [0xBE, 0xBA, 0xFE, 0xCA],
        [0xCA, 0xFE, 0xBA, 0xBF],
        [0xBF, 0xBA, 0xFE, 0xCA],
    ]
}

/// Current official Google signing boundary for Antigravity.app and AGY CLI.
nonisolated enum AntigravityOfficialExecutableTrustPolicy {
    static let teamIdentifier = "EQHXZ8M8AV"
    static let appSigningIdentifier =
        AntigravityAppBundleIdentity.requiredBundleIdentifier
    static let languageServerSigningIdentifier =
        "language_server"
    static let agySigningIdentifier = "cli"

    /// Designated requirement emitted by the current Google-signed
    /// `Contents/Resources/bin/language_server` binary.
    static let languageServerDesignatedRequirement =
        """
        identifier "\(languageServerSigningIdentifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """

    /// Designated requirement emitted by Google's official AGY CLI.
    static let agyDesignatedRequirement =
        """
        identifier "\(agySigningIdentifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """

    static func acceptsApp(
        _ identity: AntigravityCodeSignatureIdentity
    ) -> Bool {
        identity.signingIdentifier == appSigningIdentifier
            && identity.teamIdentifier == teamIdentifier
    }

    static func acceptsAGY(
        _ identity: AntigravityCodeSignatureIdentity
    ) -> Bool {
        identity.signingIdentifier == agySigningIdentifier
            && identity.teamIdentifier == teamIdentifier
    }
}

nonisolated struct AntigravityProductionExecutableCandidates:
    Sendable,
    Equatable
{
    let appBundleRoots: [URL]
    let agyExecutableURLs: [URL]

    init(
        homeDirectoryURL: URL,
        environment: [String: String] = [:]
    ) {
        let home = homeDirectoryURL.standardizedFileURL
        appBundleRoots = [
            URL(
                fileURLWithPath: "/Applications/Antigravity.app",
                isDirectory: true
            ),
            home
                .appendingPathComponent(
                    "Applications",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "Antigravity.app",
                    isDirectory: true
                ),
        ]
        var executableCandidates: [URL] = []
        if let override =
                environment["ANTIGRAVITY_CLI_PATH"]?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
           override.hasPrefix("/")
        {
            executableCandidates.append(
                URL(
                    fileURLWithPath: override,
                    isDirectory: false
                )
            )
        }
        executableCandidates.append(contentsOf: [
            home
                .appendingPathComponent(
                    ".local/bin",
                    isDirectory: true
                )
                .appendingPathComponent("agy", isDirectory: false),
            URL(
                fileURLWithPath: "/opt/homebrew/bin/agy",
                isDirectory: false
            ),
            URL(
                fileURLWithPath: "/usr/local/bin/agy",
                isDirectory: false
            ),
        ])
        if let path = environment["PATH"] {
            executableCandidates.append(
                contentsOf: path
                    .split(separator: ":")
                    .map(String.init)
                    .filter { $0.hasPrefix("/") }
                    .map {
                        URL(
                            fileURLWithPath: $0,
                            isDirectory: true
                        )
                        .appendingPathComponent(
                            "agy",
                            isDirectory: false
                        )
                    }
            )
        }

        var seen = Set<String>()
        agyExecutableURLs =
            executableCandidates.compactMap {
                let standardized =
                    $0.standardizedFileURL
                guard seen.insert(
                    standardized.path
                ).inserted else {
                    return nil
                }
                return standardized
            }
    }
}

nonisolated enum AntigravityAGYExecutableDiscoveryStatus:
    Sendable,
    Equatable
{
    case verified(displayPath: String)
    case notFound
    case rejected
}

/// A valid empty resolution is intentional. Local discovery can remain
/// unavailable and Google OAuth can still be composed without enabling managed
/// AGY launch.
nonisolated struct AntigravityProductionExecutableResolution:
    Sendable
{
    let catalog: AntigravityExecutableCatalog
    let managedLaunchExecutable: AntigravityCanonicalExecutable?
    let agyExecutableStatus:
        AntigravityAGYExecutableDiscoveryStatus
}

/// Builds the exact production allowlist without invoking a shell or executing
/// a candidate.
nonisolated struct AntigravityProductionExecutableCatalogResolver:
    Sendable
{
    private let candidates: AntigravityProductionExecutableCandidates
    private let homeDirectoryURL: URL
    private let fileSystem:
        any AntigravityProductionExecutableResolverFileSystem
    private let trustInspector:
        any AntigravityExecutableTrustInspecting
    private let fileIdentityInspector:
        any AntigravityExecutableFileIdentityInspecting

    init(
        homeDirectoryURL: URL =
            FileManager.default.realHomeDirectory,
        environment: [String: String] =
            ProcessInfo.processInfo.environment,
        fileSystem:
            any AntigravityProductionExecutableResolverFileSystem =
                AntigravitySystemProductionExecutableResolverFileSystem(),
        trustInspector:
            any AntigravityExecutableTrustInspecting =
                AntigravitySystemExecutableTrustInspector(),
        fileIdentityInspector:
            any AntigravityExecutableFileIdentityInspecting =
                AntigravitySystemExecutableFileIdentityInspector()
    ) {
        self.homeDirectoryURL =
            homeDirectoryURL.standardizedFileURL
        candidates = AntigravityProductionExecutableCandidates(
            homeDirectoryURL: homeDirectoryURL,
            environment: environment
        )
        self.fileSystem = fileSystem
        self.trustInspector = trustInspector
        self.fileIdentityInspector = fileIdentityInspector
    }

    func resolve() -> AntigravityProductionExecutableResolution {
        let verifiedAppRoots = candidates.appBundleRoots.filter {
            isVerifiedAppBundle(at: $0)
        }
        let discoverableAGYEntries = candidates.agyExecutableURLs
            .compactMap {
                verifiedAGYExecutable(at: $0)
            }
        let discoverableAGYURLs = discoverableAGYEntries.map(\.url)
        let identitiesByCanonicalPath = Dictionary(
            uniqueKeysWithValues: discoverableAGYEntries.map {
                (
                    fileSystem.canonicalURL(for: $0.url).path,
                    $0.identity
                )
            }
        )
        let catalog = AntigravityExecutableCatalog(
            appBundleRoots: verifiedAppRoots,
            agyExecutableURLs: discoverableAGYURLs,
            agyFileIdentitiesByCanonicalPath:
                identitiesByCanonicalPath,
            requiresStableFileIdentity: true,
            fileIdentityInspector: fileIdentityInspector,
            fileSystem: fileSystem
        )
        let managedLaunchExecutable = discoverableAGYURLs.lazy
            .compactMap { catalog.executable(matching: $0) }
            .first
        let agyExecutableStatus:
            AntigravityAGYExecutableDiscoveryStatus
        if let managedLaunchExecutable {
            agyExecutableStatus = .verified(
                displayPath: displayPath(
                    for: managedLaunchExecutable
                        .canonicalURL
                )
            )
        } else if candidates.agyExecutableURLs.contains(
            where: fileSystem.itemExists
        ) {
            agyExecutableStatus = .rejected
        } else {
            agyExecutableStatus = .notFound
        }

        return AntigravityProductionExecutableResolution(
            catalog: catalog,
            managedLaunchExecutable: managedLaunchExecutable,
            agyExecutableStatus: agyExecutableStatus
        )
    }

    private struct VerifiedAGYExecutable {
        let url: URL
        let identity: AntigravityExecutableFileIdentity
    }

    private func isVerifiedAppBundle(at candidate: URL) -> Bool {
        let exactURL = candidate.standardizedFileURL
        // This static check is an installation filter, not the final process
        // trust authority: Security.framework documents static validation as
        // unsafe under concurrent filesystem modification. Process discovery
        // therefore also requires the running language_server to satisfy
        // Google's exact dynamic designated requirement.
        guard !fileSystem.isSymbolicLink(at: exactURL),
              fileSystem.canonicalURL(for: exactURL).path
                == exactURL.path,
              fileSystem.isDirectory(at: exactURL),
              fileSystem.bundleIdentifier(at: exactURL)
                == AntigravityAppBundleIdentity
                    .requiredBundleIdentifier,
              let identity = trustInspector.validatedIdentity(
                  at: exactURL
              ),
              AntigravityOfficialExecutableTrustPolicy
                .acceptsApp(identity)
        else {
            return false
        }
        return true
    }

    /// Borrowed discovery and automatic managed launch use the same official
    /// Google signing boundary. The captured vnode identity is retained in the
    /// catalog and rechecked before process acceptance and launch.
    private func verifiedAGYExecutable(
        at candidate: URL
    ) -> VerifiedAGYExecutable? {
        let exactURL = candidate.standardizedFileURL
        guard !fileSystem.isSymbolicLink(at: exactURL),
              fileSystem.canonicalURL(for: exactURL).path
                == exactURL.path,
              fileSystem.isExecutableRegularFile(at: exactURL),
              fileSystem.hasMachOHeader(at: exactURL),
              fileSystem.hasSecureOwnershipAndPermissions(
                  at: exactURL
              ),
              let codeIdentity =
                trustInspector.validatedIdentity(
                    at: exactURL,
                    satisfying:
                        AntigravityOfficialExecutableTrustPolicy
                            .agyDesignatedRequirement
                ),
              AntigravityOfficialExecutableTrustPolicy
                .acceptsAGY(codeIdentity),
              let identity = fileIdentityInspector.identity(
                  at: exactURL
              )
        else {
            return nil
        }
        return VerifiedAGYExecutable(
            url: exactURL,
            identity: identity
        )
    }

    private func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = homeDirectoryURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
