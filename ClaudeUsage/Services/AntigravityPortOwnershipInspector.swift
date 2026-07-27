import Foundation

nonisolated protocol AntigravityPortOwnershipInspecting: Sendable {
    func listeningEndpoints(
        ownedBy processIDs: Set<Int32>,
        timeout: TimeInterval
    ) async throws -> [Int32: Set<AntigravityOwnedListeningEndpoint>]
}

nonisolated enum AntigravityPortResolution: Sendable, Equatable {
    case selected(AntigravityOwnedListeningEndpoint)
    case noListeningPort
    case requestedPortNotOwned
    case ambiguous([AntigravityOwnedListeningEndpoint])
}

nonisolated enum AntigravityPortOwnershipError: Error, Equatable {
    case invalidProcessID
    case helperUnavailable
    case helperFailed(Int32)
    case malformedOutput
}

nonisolated struct AntigravityOwnedListeningEndpoint:
    Sendable,
    Hashable,
    Equatable
{
    let host: AntigravityLoopbackHost
    let port: AntigravityTCPPort
}

nonisolated struct AntigravityLsofListeningRecord: Sendable, Equatable {
    let processID: Int32
    let fileDescriptor: String
    let endpoint: AntigravityOwnedListeningEndpoint
}

/// Parses `lsof -F0pfnPT` as a stream of NUL-delimited fields.
///
/// Records are committed only when PID, file descriptor, TCP protocol,
/// LISTEN state, and a valid numeric port have all been observed. Newlines
/// emitted between lsof record groups are separators, never field content.
nonisolated struct AntigravityLsofNULParser: Sendable {
    private var bufferedBytes: [UInt8] = []
    private var currentProcessID: Int32?
    private var currentFile: FileState?
    private var records: [AntigravityLsofListeningRecord] = []
    private var malformedFieldObserved = false

    mutating func consume(_ data: Data) {
        for byte in data {
            if byte == 0 {
                consumeField(bufferedBytes)
                bufferedBytes.removeAll(keepingCapacity: true)
            } else {
                bufferedBytes.append(byte)
            }
        }
    }

    mutating func finish() throws -> [AntigravityLsofListeningRecord] {
        if !bufferedBytes.isEmpty {
            consumeField(bufferedBytes)
            bufferedBytes.removeAll()
        }
        flushCurrentFile()

        guard !malformedFieldObserved else {
            throw AntigravityPortOwnershipError.malformedOutput
        }
        return records
    }

    private mutating func consumeField(_ rawBytes: [UInt8]) {
        let trimmed = rawBytes.drop(while: Self.isRecordSeparator)
        guard let prefix = trimmed.first else {
            return
        }

        let valueBytes = trimmed.dropFirst()
        guard let value = String(bytes: valueBytes, encoding: .utf8) else {
            malformedFieldObserved = true
            return
        }

        switch prefix {
        case 0x70: // p
            flushCurrentFile()
            guard let processID = Int32(value), processID > 0 else {
                currentProcessID = nil
                malformedFieldObserved = true
                return
            }
            currentProcessID = processID

        case 0x66: // f
            flushCurrentFile()
            guard !value.isEmpty else {
                malformedFieldObserved = true
                return
            }
            currentFile = FileState(fileDescriptor: value)

        case 0x6E: // n
            guard currentFile != nil else {
                malformedFieldObserved = true
                return
            }
            currentFile?.name = value

        case 0x50: // P
            guard currentFile != nil else {
                malformedFieldObserved = true
                return
            }
            currentFile?.protocolName = value

        case 0x54: // T
            guard currentFile != nil else {
                malformedFieldObserved = true
                return
            }
            if value == "ST=LISTEN" {
                currentFile?.isListening = true
            }

        default:
            break
        }
    }

    private mutating func flushCurrentFile() {
        defer { currentFile = nil }
        guard let processID = currentProcessID,
              let file = currentFile,
              file.protocolName.caseInsensitiveCompare("TCP") == .orderedSame,
              file.isListening,
              let name = file.name,
              let endpoint = Self.endpoint(from: name) else {
            return
        }

        records.append(
            AntigravityLsofListeningRecord(
                processID: processID,
                fileDescriptor: file.fileDescriptor,
                endpoint: endpoint
            )
        )
    }

    private static func endpoint(
        from name: String
    ) -> AntigravityOwnedListeningEndpoint? {
        let host: AntigravityLoopbackHost
        let rawPort: Substring

        if name.hasPrefix("127.0.0.1:") {
            host = .ipv4
            rawPort = name.dropFirst("127.0.0.1:".count)
        } else if name.hasPrefix("[::1]:") {
            host = .ipv6
            rawPort = name.dropFirst("[::1]:".count)
        } else {
            return nil
        }

        guard !rawPort.isEmpty,
              rawPort.allSatisfy(\.isNumber),
              let value = Int(rawPort),
              let port = AntigravityTCPPort(value) else {
            return nil
        }
        return AntigravityOwnedListeningEndpoint(host: host, port: port)
    }

    private static func isRecordSeparator(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    private struct FileState: Sendable {
        let fileDescriptor: String
        var name: String?
        var protocolName = ""
        var isListening = false
    }
}

nonisolated final class AntigravityPortOwnershipInspector:
    AntigravityPortOwnershipInspecting,
    @unchecked Sendable
{
    private let subprocessRunner: any AntigravityOwnedSubprocessRunning
    private let lsofExecutableURL: URL

    init(
        subprocessRunner: any AntigravityOwnedSubprocessRunning = AntigravityOwnedSubprocessRunner(),
        lsofExecutableURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.subprocessRunner = subprocessRunner
        if let lsofExecutableURL {
            self.lsofExecutableURL = lsofExecutableURL
        } else if fileManager.isExecutableFile(atPath: "/usr/sbin/lsof") {
            self.lsofExecutableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        } else {
            self.lsofExecutableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        }
    }

    func listeningEndpoints(
        ownedBy processIDs: Set<Int32>,
        timeout: TimeInterval
    ) async throws -> [Int32: Set<AntigravityOwnedListeningEndpoint>] {
        guard processIDs.allSatisfy({ $0 > 0 }) else {
            throw AntigravityPortOwnershipError.invalidProcessID
        }
        guard !processIDs.isEmpty else {
            return [:]
        }

        let pidList = processIDs.sorted().map(String.init).joined(separator: ",")
        let result: AntigravityOwnedSubprocessResult
        do {
            result = try await subprocessRunner.run(
                AntigravityOwnedSubprocessRequest(
                    executableURL: lsofExecutableURL,
                    arguments: [
                        "-nP",
                        "-a",
                        "-p", pidList,
                        "-iTCP",
                        "-sTCP:LISTEN",
                        "-F0pfnPT",
                    ],
                    timeout: timeout
                )
            )
        } catch AntigravityOwnedSubprocessError.executableNotAllowed {
            throw AntigravityPortOwnershipError.helperUnavailable
        }

        // lsof returns 1 when no matching files exist. That is a valid empty
        // observation, not a discovery failure.
        if result.terminationStatus == 1, result.standardOutput.isEmpty {
            return [:]
        }
        guard result.terminationStatus == 0 else {
            throw AntigravityPortOwnershipError.helperFailed(result.terminationStatus)
        }

        var parser = AntigravityLsofNULParser()
        parser.consume(result.standardOutput)
        let records = try parser.finish()

        var endpointsByProcess:
            [Int32: Set<AntigravityOwnedListeningEndpoint>] = [:]
        for record in records where processIDs.contains(record.processID) {
            endpointsByProcess[record.processID, default: []]
                .insert(record.endpoint)
        }
        return endpointsByProcess
    }

    static func resolvePort(
        requestedPort: AntigravityTCPPort?,
        ownedEndpoints: Set<AntigravityOwnedListeningEndpoint>
    ) -> AntigravityPortResolution {
        let trustedEndpoints = ownedEndpoints.filter {
            $0.host == .ipv4
        }
        if let requestedPort {
            let matches = Array(
                trustedEndpoints.filter { $0.port == requestedPort }
            )
            switch matches.count {
            case 0:
                return .requestedPortNotOwned
            case 1:
                return .selected(matches[0])
            default:
                return .ambiguous(sorted(matches))
            }
        }

        switch trustedEndpoints.count {
        case 0:
            return .noListeningPort
        case 1:
            return .selected(trustedEndpoints.first!)
        default:
            return .ambiguous(sorted(Array(trustedEndpoints)))
        }
    }

    private static func sorted(
        _ endpoints: [AntigravityOwnedListeningEndpoint]
    ) -> [AntigravityOwnedListeningEndpoint] {
        endpoints.sorted {
            if $0.port != $1.port {
                return $0.port.rawValue < $1.port.rawValue
            }
            return $0.host.rawValue < $1.host.rawValue
        }
    }
}
