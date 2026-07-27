import Foundation

nonisolated struct AntigravityTCPPort:
    RawRepresentable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    let rawValue: UInt16

    init?(rawValue: UInt16) {
        guard rawValue > 0 else {
            return nil
        }
        self.rawValue = rawValue
    }

    init?(_ value: Int) {
        guard (1...Int(UInt16.max)).contains(value),
              let rawValue = UInt16(exactly: value)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    var description: String {
        String(rawValue)
    }
}

nonisolated struct AntigravityUserID:
    RawRepresentable,
    Hashable,
    Sendable
{
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

nonisolated struct AntigravityProcessStartTime:
    Hashable,
    Sendable,
    Comparable
{
    let seconds: Int64
    let microseconds: Int32

    init?(seconds: Int64, microseconds: Int32) {
        guard seconds >= 0, (0..<1_000_000).contains(microseconds) else {
            return nil
        }
        self.seconds = seconds
        self.microseconds = microseconds
    }

    static func < (
        lhs: AntigravityProcessStartTime,
        rhs: AntigravityProcessStartTime
    ) -> Bool {
        if lhs.seconds != rhs.seconds {
            return lhs.seconds < rhs.seconds
        }
        return lhs.microseconds < rhs.microseconds
    }
}

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

/// A process identity after UID, start time, and executable catalog validation.
///
/// PID alone is never sufficient because the operating system may reuse it.
nonisolated struct AntigravityVerifiedProcessIdentity: Hashable, Sendable {
    let processID: Int32
    let effectiveUserID: AntigravityUserID
    let realUserID: AntigravityUserID
    let startedAt: AntigravityProcessStartTime
    let executable: AntigravityCanonicalExecutable

    init?(
        processID: Int32,
        effectiveUserID: AntigravityUserID,
        realUserID: AntigravityUserID,
        startedAt: AntigravityProcessStartTime,
        executable: AntigravityCanonicalExecutable
    ) {
        guard processID > 0 else {
            return nil
        }
        self.processID = processID
        self.effectiveUserID = effectiveUserID
        self.realUserID = realUserID
        self.startedAt = startedAt
        self.executable = executable
    }
}

nonisolated enum AntigravityRuntimeTransport: String, Codable, Sendable {
    case antigravityApp
    case agyCLI
}

nonisolated enum AntigravityRuntimeOwnership: String, Codable, Sendable {
    /// A process owned by another application, such as Antigravity.app.
    case external
    /// An independently launched AGY process that ClaudeUsage may use but must
    /// never signal or terminate.
    case borrowed
    /// An AGY process explicitly launched and lifecycle-managed by ClaudeUsage.
    case managed
    /// ClaudeUsage launched this exact process, but cleanup could not prove
    /// that it and all descendants exited. It must not be rediscovered as a
    /// borrowed runtime.
    case quarantined
}

nonisolated enum AntigravityRuntimeQueryability: String, Codable, Sendable {
    /// Process discovery has not performed an RPC capability check yet.
    case unknown
    case authenticationRequired
    case limitedCapability
    case queryable
}

nonisolated struct AntigravityCSRFToken:
    Sendable,
    Equatable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let value: String

    init?(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.value = value
    }

    var description: String {
        "<redacted>"
    }

    var debugDescription: String {
        description
    }
}

/// Connection hints are untrusted until port ownership and loopback binding are
/// verified. In particular, a requested port is never an endpoint by itself.
nonisolated struct AntigravityRuntimeConnectionHints:
    Sendable,
    Equatable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    let requestedPort: AntigravityTCPPort?
    let csrfToken: AntigravityCSRFToken?

    init(
        requestedPort: AntigravityTCPPort? = nil,
        csrfToken: AntigravityCSRFToken? = nil
    ) {
        self.requestedPort = requestedPort
        self.csrfToken = csrfToken
    }

    var description: String {
        "AntigravityRuntimeConnectionHints(requestedPort: \(requestedPort?.description ?? "nil"), csrfToken: \(csrfToken == nil ? "nil" : "<redacted>"))"
    }

    var debugDescription: String {
        description
    }
}

nonisolated enum AntigravityLoopbackHost: String, Codable, Sendable {
    case ipv4 = "127.0.0.1"
    case ipv6 = "::1"

    var urlHost: String {
        switch self {
        case .ipv4:
            rawValue
        case .ipv6:
            "[\(rawValue)]"
        }
    }
}

nonisolated enum AntigravityRuntimeEndpointAuthentication: Sendable, Equatable {
    case appCSRF(AntigravityCSRFToken)
    case cliTokenless
}

/// A HTTPS loopback endpoint whose port ownership is bound to a verified
/// process identity. Its initializer rejects transport/authentication mixes
/// that could accidentally send an app CSRF token to an AGY endpoint.
nonisolated struct AntigravityVerifiedRuntimeEndpoint: Sendable, Equatable {
    let processIdentity: AntigravityVerifiedProcessIdentity
    let host: AntigravityLoopbackHost
    let port: AntigravityTCPPort
    let transport: AntigravityRuntimeTransport
    let ownership: AntigravityRuntimeOwnership
    let authentication: AntigravityRuntimeEndpointAuthentication

    var url: URL {
        // All construction paths force HTTPS and an exact loopback host.
        URL(string: "https://\(host.urlHost):\(port.rawValue)")!
    }

    init?(
        processIdentity: AntigravityVerifiedProcessIdentity,
        host: AntigravityLoopbackHost,
        port: AntigravityTCPPort,
        transport: AntigravityRuntimeTransport,
        ownership: AntigravityRuntimeOwnership,
        authentication: AntigravityRuntimeEndpointAuthentication
    ) {
        // TLS exceptions and request construction are pinned to the exact
        // IPv4 loopback target. An IPv6 listener may be observed by discovery
        // but is not a trusted RPC endpoint in this release.
        guard host == .ipv4 else {
            return nil
        }
        switch (
            processIdentity.executable.role,
            transport,
            ownership,
            authentication
        ) {
        case (.appLanguageServer, .antigravityApp, .external, .appCSRF):
            break
        case (.agyCLI, .agyCLI, .borrowed, .cliTokenless),
             (.agyCLI, .agyCLI, .managed, .cliTokenless):
            break
        default:
            return nil
        }
        self.processIdentity = processIdentity
        self.host = host
        self.port = port
        self.transport = transport
        self.ownership = ownership
        self.authentication = authentication
    }
}

nonisolated struct AntigravityRuntimeProcessCandidate: Sendable, Equatable {
    let processIdentity: AntigravityVerifiedProcessIdentity
    let ownership: AntigravityRuntimeOwnership
    let connectionHints: AntigravityRuntimeConnectionHints
    let queryability: AntigravityRuntimeQueryability

    var transport: AntigravityRuntimeTransport {
        switch processIdentity.executable.role {
        case .appLanguageServer:
            .antigravityApp
        case .agyCLI:
            .agyCLI
        }
    }

    init?(
        processIdentity: AntigravityVerifiedProcessIdentity,
        ownership: AntigravityRuntimeOwnership,
        connectionHints: AntigravityRuntimeConnectionHints = .init(),
        queryability: AntigravityRuntimeQueryability = .unknown
    ) {
        switch (processIdentity.executable.role, ownership) {
        case (.appLanguageServer, .external),
             (.agyCLI, .borrowed),
             (.agyCLI, .managed):
            break
        default:
            return nil
        }
        self.processIdentity = processIdentity
        self.ownership = ownership
        self.connectionHints = connectionHints
        self.queryability = queryability
    }
}

nonisolated struct AntigravityRuntimeDiscoverySnapshot: Sendable, Equatable {
    let installations: [AntigravityCanonicalExecutable]
    let processes: [AntigravityRuntimeProcessCandidate]
    let endpoints: [AntigravityVerifiedRuntimeEndpoint]
    let observedAt: Date

    var isInstalled: Bool {
        !installations.isEmpty
    }

    var isRunning: Bool {
        !processes.isEmpty
    }
}
