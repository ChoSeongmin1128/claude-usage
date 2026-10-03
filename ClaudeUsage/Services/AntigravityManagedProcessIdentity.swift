import Darwin
import Foundation

nonisolated protocol AntigravityManagedProcessIdentityProviding:
    Sendable
{
    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity?

    func processGroupID(for processID: Int32) -> Int32?
}

nonisolated protocol AntigravityKernelProcessIdentityReading:
    Sendable
{
    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity?
}

/// Isolates the one Darwin-private process-info flavor used by managed
/// process containment.
///
/// The returned 56-byte structure is part of Apple's XNU user-space ABI but
/// is not declared by the public macOS SDK. Failure to read it disables
/// managed launch/recovery rather than falling back to PID-only authority.
nonisolated struct AntigravitySystemKernelProcessIdentityReader:
    AntigravityKernelProcessIdentityReading
{
    private struct RawUniqueIdentifierInfo {
        var executableUUIDHigh: UInt64 = 0
        var executableUUIDLow: UInt64 = 0
        var uniqueID: UInt64 = 0
        var parentUniqueID: UInt64 = 0
        var pidVersion: Int32 = 0
        var originalParentPIDVersion: Int32 = 0
        var reserved2: UInt64 = 0
        var reserved3: UInt64 = 0
    }

    private static let uniqueIdentifierFlavor: Int32 = 17
    private static let expectedSize = 56
    private let includeTerminatedProcesses: Bool

    init(
        includeTerminatedProcesses: Bool = false
    ) {
        self.includeTerminatedProcesses =
            includeTerminatedProcesses
    }

    func kernelIdentity(
        for processID: Int32
    ) -> AntigravityKernelProcessIdentity? {
        guard processID > 1,
            MemoryLayout<RawUniqueIdentifierInfo>.size
                == Self.expectedSize
        else {
            return nil
        }

        var info = RawUniqueIdentifierInfo()
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processID,
                Self.uniqueIdentifierFlavor,
                includeTerminatedProcesses ? 1 : 0,
                $0,
                Int32(Self.expectedSize)
            )
        }
        guard result == Self.expectedSize else {
            return nil
        }
        return AntigravityKernelProcessIdentity(
            uniqueID: info.uniqueID,
            parentUniqueID: info.parentUniqueID,
            pidVersion: info.pidVersion
        )
    }
}

/// Produces a stable identity by double-reading both BSD metadata and the
/// executable image plus the kernel unique identifier. Callers still decide
/// whether that image is an allowed AGY binary or the current ClaudeUsage
/// owner executable.
nonisolated final class AntigravityManagedProcessIdentityProvider:
    AntigravityManagedProcessIdentityProviding,
    @unchecked Sendable
{
    private let libprocReader: any AntigravityLibprocReading
    private let kernelIdentityReader: any AntigravityKernelProcessIdentityReading

    init(
        libprocReader: any AntigravityLibprocReading =
            AntigravitySystemLibprocReader(),
        kernelIdentityReader:
            any AntigravityKernelProcessIdentityReading =
            AntigravitySystemKernelProcessIdentityReader()
    ) {
        self.libprocReader = libprocReader
        self.kernelIdentityReader = kernelIdentityReader
    }

    func identity(
        for processID: Int32
    ) -> AntigravityRecordedProcessIdentity? {
        guard let before = libprocReader.bsdInfo(for: processID),
            let kernelBefore =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
            let executableBefore =
                libprocReader.executableURL(for: processID)?
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            let during = libprocReader.bsdInfo(for: processID),
            before == during,
            let kernelDuring =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
            kernelBefore == kernelDuring,
            let executableAfter =
                libprocReader.executableURL(for: processID)?
                .resolvingSymlinksInPath()
                .standardizedFileURL,
            executableBefore == executableAfter,
            let after = libprocReader.bsdInfo(for: processID),
            before == after,
            let kernelAfter =
                kernelIdentityReader.kernelIdentity(
                    for: processID
                ),
            kernelBefore == kernelAfter
        else {
            return nil
        }

        return AntigravityRecordedProcessIdentity(
            pid: processID,
            effectiveUserID: before.effectiveUserID.rawValue,
            realUserID: before.realUserID.rawValue,
            startedAtSeconds: before.startedAt.seconds,
            startedAtMicroseconds: before.startedAt.microseconds,
            executablePath: executableAfter.path,
            kernelIdentity: kernelAfter
        )
    }

    func processGroupID(for processID: Int32) -> Int32? {
        guard processID > 0 else { return nil }
        let groupID = getpgid(processID)
        return groupID > 0 ? groupID : nil
    }
}

nonisolated extension AntigravityRecordedProcessIdentity {
    func verifiedIdentity(
        matching executable: AntigravityCanonicalExecutable
    ) -> AntigravityVerifiedProcessIdentity? {
        guard executable.role == .agyCLI,
            executablePath
                == executable.canonicalURL.standardizedFileURL.path,
            let startedAt = AntigravityProcessStartTime(
                seconds: startedAtSeconds,
                microseconds: startedAtMicroseconds
            )
        else {
            return nil
        }
        return AntigravityVerifiedProcessIdentity(
            processID: pid,
            effectiveUserID:
                AntigravityUserID(rawValue: effectiveUserID),
            realUserID:
                AntigravityUserID(rawValue: realUserID),
            startedAt: startedAt,
            executable: executable
        )
    }
}

nonisolated struct AntigravityBSDProcessInfo: Sendable, Equatable {
    let processID: Int32
    let effectiveUserID: AntigravityUserID
    let realUserID: AntigravityUserID
    let startedAt: AntigravityProcessStartTime
}

nonisolated protocol AntigravityLibprocReading: Sendable {
    func bsdInfo(for processID: Int32) -> AntigravityBSDProcessInfo?
    func executableURL(for processID: Int32) -> URL?
}

nonisolated struct AntigravitySystemLibprocReader: AntigravityLibprocReading {
    func bsdInfo(for processID: Int32) -> AntigravityBSDProcessInfo? {
        guard processID > 0 else {
            return nil
        }

        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard result == expectedSize,
            info.pbi_pid == UInt32(processID),
            let seconds = Int64(exactly: info.pbi_start_tvsec),
            let microseconds = Int32(exactly: info.pbi_start_tvusec),
            let startedAt = AntigravityProcessStartTime(
                seconds: seconds,
                microseconds: microseconds
            )
        else {
            return nil
        }

        return AntigravityBSDProcessInfo(
            processID: processID,
            effectiveUserID: AntigravityUserID(rawValue: info.pbi_uid),
            realUserID: AntigravityUserID(rawValue: info.pbi_ruid),
            startedAt: startedAt
        )
    }

    func executableURL(for processID: Int32) -> URL? {
        guard processID > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(
                processID,
                pointer.baseAddress,
                UInt32(pointer.count)
            )
        }
        guard result > 0 else {
            return nil
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
}