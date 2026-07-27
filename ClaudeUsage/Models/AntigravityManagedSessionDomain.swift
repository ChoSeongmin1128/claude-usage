import Foundation

nonisolated enum AntigravityManagedLaunchAuthorization:
    Sendable,
    Equatable
{
    /// Automatic refresh and source selection must use this value.
    case disabled

    /// Only an explicit advanced-setting opt-in may construct this value.
    case userOptIn(idleTimeout: Duration = .seconds(180))

    var idleTimeout: Duration? {
        switch self {
        case .disabled:
            nil
        case .userOptIn(let idleTimeout):
            idleTimeout
        }
    }
}

nonisolated enum AntigravityManagedSessionResetReason:
    String,
    Sendable,
    Equatable
{
    case userRequested
    case authenticationRequired
    case unhealthyRuntime
    case appShutdown
}

nonisolated enum AntigravityManagedSessionError:
    Error,
    Sendable,
    Equatable
{
    case launchDisabled
    case invalidIdleTimeout
    case executableNotAllowed
    case differentExecutableInUse
    case resetPending
    case appShuttingDown
    case launchFailed
    case processGroupInvalid
    case processIdentityUnavailable
    case ownerIdentityUnavailable
    case recordPersistenceFailed
    case recordRecoveryBlocked
    case launchCoordinationUnavailable
    case readinessTimedOut
    case processExited(Int32)
    case interactionRequired(AntigravityManagedCLIInteraction)
    case endpointUnavailable
    case cancelled
}

/// Exact macOS boot-session identity. PID and kernel unique-ID evidence from
/// one boot must never authorize signals during another boot.
nonisolated struct AntigravityBootSessionID:
    RawRepresentable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

nonisolated enum AntigravityManagedLaunchBarrier:
    String,
    Codable,
    Equatable,
    Sendable
{
    case darwinStartSuspendedV1
}

nonisolated struct AntigravityManagedExecutableDescriptor:
    Codable,
    Equatable,
    Sendable
{
    let role: AntigravityExecutableRole
    let canonicalPath: String

    init?(executable: AntigravityCanonicalExecutable) {
        self.init(
            role: executable.role,
            canonicalPath:
                executable.canonicalURL.standardizedFileURL.path
        )
    }

    init?(
        role: AntigravityExecutableRole,
        canonicalPath: String
    ) {
        guard role == .agyCLI,
              canonicalPath.hasPrefix("/"),
              !canonicalPath.contains("\0"),
              canonicalPath.utf8.count <= Int(PATH_MAX),
              URL(fileURLWithPath: canonicalPath)
                .standardizedFileURL.path == canonicalPath else {
            return nil
        }
        self.role = role
        self.canonicalPath = canonicalPath
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case canonicalPath
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        guard let descriptor = Self(
            role: try container.decode(
                AntigravityExecutableRole.self,
                forKey: .role
            ),
            canonicalPath: try container.decode(
                String.self,
                forKey: .canonicalPath
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Invalid managed executable descriptor"
                )
            )
        }
        self = descriptor
    }
}

/// Durable evidence written before `posix_spawn`.
///
/// The intent does not authorize runtime reuse. It only lets the next app
/// instance either prove there is no child, or atomically promote one exact
/// suspended-launch descendant into normal recovery state.
nonisolated struct AntigravityManagedLaunchIntent:
    Codable,
    Equatable,
    Sendable
{
    let sessionID: UUID
    let bootSessionID: AntigravityBootSessionID
    let owner: AntigravityRecordedProcessIdentity
    let executable: AntigravityManagedExecutableDescriptor
    let launchBarrier: AntigravityManagedLaunchBarrier
    let createdAt: Date

    init?(
        sessionID: UUID,
        bootSessionID: AntigravityBootSessionID,
        owner: AntigravityRecordedProcessIdentity,
        executable: AntigravityManagedExecutableDescriptor,
        launchBarrier: AntigravityManagedLaunchBarrier =
            .darwinStartSuspendedV1,
        createdAt: Date
    ) {
        guard createdAt.timeIntervalSince1970.isFinite,
              createdAt.timeIntervalSince1970 >= 0 else {
            return nil
        }
        let milliseconds = (
            createdAt.timeIntervalSince1970 * 1_000
        ).rounded(.towardZero)
        guard milliseconds.isFinite else { return nil }

        self.sessionID = sessionID
        self.bootSessionID = bootSessionID
        self.owner = owner
        self.executable = executable
        self.launchBarrier = launchBarrier
        self.createdAt = Date(
            timeIntervalSince1970: milliseconds / 1_000
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case bootSessionID
        case owner
        case executable
        case launchBarrier
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        guard let intent = Self(
            sessionID: try container.decode(
                UUID.self,
                forKey: .sessionID
            ),
            bootSessionID: try container.decode(
                AntigravityBootSessionID.self,
                forKey: .bootSessionID
            ),
            owner: try container.decode(
                AntigravityRecordedProcessIdentity.self,
                forKey: .owner
            ),
            executable: try container.decode(
                AntigravityManagedExecutableDescriptor.self,
                forKey: .executable
            ),
            launchBarrier: try container.decode(
                AntigravityManagedLaunchBarrier.self,
                forKey: .launchBarrier
            ),
            createdAt: try container.decode(
                Date.self,
                forKey: .createdAt
            )
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Invalid managed launch intent"
                )
            )
        }
        self = intent
    }
}

nonisolated struct AntigravityManagedRuntime:
    Sendable,
    Equatable
{
    let processIdentity: AntigravityVerifiedProcessIdentity
    let endpoint: AntigravityVerifiedRuntimeEndpoint

    init?(
        processIdentity: AntigravityVerifiedProcessIdentity,
        endpoint: AntigravityVerifiedRuntimeEndpoint
    ) {
        guard endpoint.processIdentity == processIdentity,
              endpoint.transport == .agyCLI,
              endpoint.ownership == .managed,
              endpoint.authentication == .cliTokenless else {
            return nil
        }
        self.processIdentity = processIdentity
        self.endpoint = endpoint
    }
}

nonisolated struct AntigravityManagedSessionDiagnostics:
    Sendable,
    Equatable
{
    let interactions: Set<AntigravityManagedCLIInteraction>
    let outputWasTruncated: Bool
}
