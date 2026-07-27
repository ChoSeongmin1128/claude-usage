import Foundation

nonisolated protocol AntigravityExecutableCatalogFileSystem: Sendable {
    func canonicalURL(for url: URL) -> URL
    func isExecutableRegularFile(at url: URL) -> Bool
    func bundleIdentifier(at appBundleRoot: URL) -> String?
}

nonisolated struct AntigravitySystemExecutableCatalogFileSystem:
    AntigravityExecutableCatalogFileSystem
{
    func canonicalURL(for url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    func isExecutableRegularFile(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .isSymbolicLinkKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            return false
        }
        return true
    }

    func bundleIdentifier(at appBundleRoot: URL) -> String? {
        Bundle(url: appBundleRoot)?.bundleIdentifier
    }
}

nonisolated protocol AntigravityExecutableRevalidating: Sendable {
    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool
}

/// Standalone production launch guard. It is intentionally independent from
/// the catalog so direct launcher use cannot bypass the reviewed-byte policy.
nonisolated struct AntigravityPinnedAGYExecutableRevalidator:
    AntigravityExecutableRevalidating
{
    private let fileIdentityInspector:
        any AntigravityExecutableFileIdentityInspecting

    init(
        fileIdentityInspector:
            any AntigravityExecutableFileIdentityInspecting =
                AntigravitySystemExecutableFileIdentityInspector()
    ) {
        self.fileIdentityInspector = fileIdentityInspector
    }

    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        guard executable.role == .agyCLI,
              let expected = executable.fileIdentity,
              AntigravityOfficialAGYBinaryDigestPolicy.accepts(
                  expected.sha256Digest
              ) else {
            return false
        }
        return fileIdentityInspector.identity(
            at: executable.canonicalURL
        ) == expected
    }
}

/// An exact, canonical allowlist of Antigravity runtime executables.
///
/// Process discovery may only accept an executable returned by this catalog.
/// Basenames, command-line substrings, and paths merely containing
/// `Antigravity.app` are intentionally insufficient.
nonisolated struct AntigravityExecutableCatalog:
    Sendable,
    AntigravityExecutableRevalidating
{
    static let appLanguageServerRelativePaths = [
        "Contents/Resources/bin/language_server",
        "Contents/Resources/bin/language_server_macos",
        "Contents/Resources/bin/language_server_macos_arm",
        "Contents/Resources/bin/language_server_macos_arm64",
        "Contents/Resources/bin/language_server_macos_x64",
    ]

    let appBundles: [AntigravityAppBundleIdentity]
    let executables: [AntigravityCanonicalExecutable]

    private let entriesByCanonicalPath: [String: AntigravityCanonicalExecutable]
    private let fileIdentityInspector:
        any AntigravityExecutableFileIdentityInspecting
    private let fileSystem: any AntigravityExecutableCatalogFileSystem

    init(
        appBundleRoots: [URL],
        agyExecutableURLs: [URL],
        agyFileIdentitiesByCanonicalPath:
            [String: AntigravityExecutableFileIdentity] = [:],
        requiresStableFileIdentity: Bool = false,
        fileIdentityInspector:
            any AntigravityExecutableFileIdentityInspecting =
                AntigravitySystemExecutableFileIdentityInspector(),
        fileSystem: any AntigravityExecutableCatalogFileSystem =
            AntigravitySystemExecutableCatalogFileSystem()
    ) {
        self.fileSystem = fileSystem
        self.fileIdentityInspector = fileIdentityInspector

        var seenBundleRoots = Set<String>()
        var resolvedBundles: [AntigravityAppBundleIdentity] = []
        for root in appBundleRoots {
            let canonicalRoot = fileSystem.canonicalURL(for: root)
            guard seenBundleRoots.insert(canonicalRoot.path).inserted,
                  canonicalRoot.pathExtension == "app",
                  fileSystem.bundleIdentifier(at: canonicalRoot)
                    == AntigravityAppBundleIdentity.requiredBundleIdentifier
            else {
                continue
            }
            resolvedBundles.append(AntigravityAppBundleIdentity(
                canonicalRootURL: canonicalRoot,
                bundleIdentifier: AntigravityAppBundleIdentity.requiredBundleIdentifier
            ))
        }
        resolvedBundles.sort { $0.canonicalRootURL.path < $1.canonicalRootURL.path }
        self.appBundles = resolvedBundles

        var resolvedEntries: [AntigravityCanonicalExecutable] = []
        var seenExecutablePaths = Set<String>()

        for bundle in resolvedBundles {
            for relativePath in Self.appLanguageServerRelativePaths {
                let exactURL = bundle.canonicalRootURL
                    .appendingPathComponent(relativePath, isDirectory: false)
                    .standardizedFileURL
                let canonicalURL = fileSystem.canonicalURL(for: exactURL)

                // Reject a symlink or other redirection away from the enumerated
                // file inside the already verified bundle root.
                guard canonicalURL.path == exactURL.path,
                      fileSystem.isExecutableRegularFile(at: canonicalURL),
                      seenExecutablePaths.insert(canonicalURL.path).inserted
                else {
                    continue
                }
                let fileIdentity = fileIdentityInspector.identity(
                    at: canonicalURL
                )
                guard !requiresStableFileIdentity
                        || fileIdentity != nil else {
                    continue
                }
                resolvedEntries.append(AntigravityCanonicalExecutable(
                    canonicalURL: canonicalURL,
                    role: .appLanguageServer,
                    appBundle: bundle,
                    fileIdentity: fileIdentity
                ))
            }
        }

        for candidateURL in agyExecutableURLs {
            let canonicalURL = fileSystem.canonicalURL(for: candidateURL)
            let fileIdentity =
                agyFileIdentitiesByCanonicalPath[
                    canonicalURL.path
                ]
            guard fileSystem.isExecutableRegularFile(at: canonicalURL),
                  !requiresStableFileIdentity
                    || fileIdentity != nil,
                  seenExecutablePaths.insert(canonicalURL.path).inserted
            else {
                continue
            }
            resolvedEntries.append(AntigravityCanonicalExecutable(
                canonicalURL: canonicalURL,
                role: .agyCLI,
                fileIdentity: fileIdentity
            ))
        }

        resolvedEntries.sort {
            if $0.role != $1.role {
                return $0.role.rawValue < $1.role.rawValue
            }
            return $0.canonicalURL.path < $1.canonicalURL.path
        }
        self.executables = resolvedEntries
        self.entriesByCanonicalPath = Dictionary(
            uniqueKeysWithValues: resolvedEntries.map { ($0.canonicalURL.path, $0) }
        )
    }

    func executable(matching url: URL) -> AntigravityCanonicalExecutable? {
        let canonicalURL = fileSystem.canonicalURL(for: url)
        return entriesByCanonicalPath[canonicalURL.path]
    }

    /// Re-establishes the startup trust decision at a later process or launch
    /// boundary. Every entry from the production resolver carries an identity;
    /// identity-less entries remain available only to deterministic fixtures
    /// that construct a catalog directly.
    func isCurrent(
        _ executable: AntigravityCanonicalExecutable
    ) -> Bool {
        let path = executable.canonicalURL.standardizedFileURL.path
        guard entriesByCanonicalPath[path] == executable else {
            return false
        }
        guard let expected = executable.fileIdentity else {
            return true
        }
        return fileIdentityInspector.matches(
            expected,
            at: executable.canonicalURL
        )
    }
}
