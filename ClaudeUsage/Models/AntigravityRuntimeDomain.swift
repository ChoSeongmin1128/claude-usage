import Foundation

nonisolated enum AntigravityExecutableRole: String, Codable, Sendable {
    case appLanguageServer
    case agyCLI
}

nonisolated struct AntigravityAppBundleIdentity: Hashable, Sendable {
    static let requiredBundleIdentifier = "com.google.antigravity"

    let canonicalRootURL: URL
    let bundleIdentifier: String
}

/// Exact on-disk identity captured while hashing one open executable vnode.
///
/// A path alone is not authority: an atomic rename can replace its target
/// after catalog construction. The digest proves reviewed bytes while the
/// vnode metadata makes same-path replacement and in-place mutation visible
/// at every later trust boundary.
nonisolated struct AntigravityExecutableFileIdentity:
    Hashable,
    Sendable
{
    let deviceID: UInt64
    let inode: UInt64
    let fileSize: UInt64
    let changeTimeSeconds: Int64
    let changeTimeNanoseconds: Int64
    let sha256Digest: String

    init?(
        deviceID: UInt64,
        inode: UInt64,
        fileSize: UInt64,
        changeTimeSeconds: Int64,
        changeTimeNanoseconds: Int64,
        sha256Digest: String
    ) {
        let normalizedDigest = sha256Digest.lowercased()
        guard inode > 0,
              changeTimeSeconds >= 0,
              (0..<1_000_000_000).contains(
                  changeTimeNanoseconds
              ),
              normalizedDigest.count == 64,
              normalizedDigest.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        self.deviceID = deviceID
        self.inode = inode
        self.fileSize = fileSize
        self.changeTimeSeconds = changeTimeSeconds
        self.changeTimeNanoseconds = changeTimeNanoseconds
        self.sha256Digest = normalizedDigest
    }
}

nonisolated struct AntigravityCanonicalExecutable: Hashable, Sendable {
    let canonicalURL: URL
    let role: AntigravityExecutableRole
    let appBundle: AntigravityAppBundleIdentity?
    let fileIdentity: AntigravityExecutableFileIdentity?

    init(
        canonicalURL: URL,
        role: AntigravityExecutableRole,
        appBundle: AntigravityAppBundleIdentity? = nil,
        fileIdentity: AntigravityExecutableFileIdentity? = nil
    ) {
        precondition(
            (role == .appLanguageServer) == (appBundle != nil),
            "An app language server must be bound to its verified app bundle"
        )
        self.canonicalURL = canonicalURL
        self.role = role
        self.appBundle = appBundle
        self.fileIdentity = fileIdentity
    }
}
