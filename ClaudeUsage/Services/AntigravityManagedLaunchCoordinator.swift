import Darwin
import Foundation

nonisolated protocol AntigravityManagedLaunchCoordinating: Sendable {
    func withExclusiveLaunch<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T

    func withExclusiveLaunch<T: Sendable>(
        deadline: AntigravityRPCDeadline,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T
}

nonisolated extension AntigravityManagedLaunchCoordinating {
    func withExclusiveLaunch<T: Sendable>(
        deadline: AntigravityRPCDeadline,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try deadline.check(.request)
        return try await withExclusiveLaunch {
            try deadline.check(.request)
            return try await operation()
        }
    }
}

nonisolated enum AntigravityManagedLaunchCoordinatorError:
    Error,
    Equatable,
    Sendable
{
    case invalidDirectory
    case invalidDirectoryOwner
    case invalidDirectoryPermissions
    case invalidLockFile
    case invalidLockFileOwner
    case invalidLockFilePermissions
    case posix(function: String, code: Int32)
}

/// Serializes the short managed-launch transaction across ClaudeUsage processes.
///
/// The lock covers recovery, process creation, identity verification, and process
/// record persistence supplied by the caller. It is released as soon as that
/// operation returns; it must not be used as a quota or idle-session lease.
nonisolated final class AntigravityManagedLaunchFileCoordinator:
    AntigravityManagedLaunchCoordinating,
    @unchecked Sendable
{
    private struct OpenedLockFile {
        let directoryDescriptor: Int32
        let lockFileDescriptor: Int32
    }

    static let lockFileName = "managed-agy-launch.lock"

    let directoryURL: URL
    var lockFileURL: URL {
        directoryURL.appendingPathComponent(Self.lockFileName)
    }

    private let fileManager: FileManager
    private let expectedUserID: uid_t
    private let retryDelayNanoseconds: UInt64

    init(
        directoryURL: URL = AntigravityStoragePaths
            .canonicalStateDirectoryURL(),
        fileManager: FileManager = .default,
        expectedUserID: uid_t = geteuid(),
        retryDelayNanoseconds: UInt64 = 25_000_000
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.expectedUserID = expectedUserID
        self.retryDelayNanoseconds = max(1, retryDelayNanoseconds)
    }

    func withExclusiveLaunch<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusiveLaunch(
            deadline: nil,
            operation
        )
    }

    func withExclusiveLaunch<T: Sendable>(
        deadline: AntigravityRPCDeadline,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusiveLaunch(
            deadline: Optional(deadline),
            operation
        )
    }

    private func withExclusiveLaunch<T: Sendable>(
        deadline: AntigravityRPCDeadline?,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try deadline?.check(.request)
        let openedLockFile = try openVerifiedLockFile()
        var ownsLock = false
        defer {
            if ownsLock {
                _ = flock(
                    openedLockFile.lockFileDescriptor,
                    LOCK_UN
                )
            }
            _ = close(openedLockFile.lockFileDescriptor)
            _ = close(openedLockFile.directoryDescriptor)
        }

        try await acquireExclusiveLock(
            openedLockFile.lockFileDescriptor,
            deadline: deadline
        )
        ownsLock = true

        // A waiting process may have moved or replaced either pathname before
        // this process obtained the advisory lock. Revalidate both opened
        // inodes against the current paths before entering the transaction.
        try validateOpenedPaths(openedLockFile)
        try Task.checkCancellation()
        try deadline?.check(.request)
        return try await operation()
    }

    private func acquireExclusiveLock(
        _ descriptor: Int32,
        deadline: AntigravityRPCDeadline?
    ) async throws {
        while true {
            try Task.checkCancellation()
            try deadline?.check(.request)
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return
            }

            let code = errno
            if code == EINTR {
                continue
            }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw AntigravityManagedLaunchCoordinatorError.posix(
                    function: "flock",
                    code: code
                )
            }
            try await Task<Never, Never>.sleep(
                nanoseconds: retryDelayNanoseconds
            )
        }
    }

    private func openVerifiedLockFile() throws -> OpenedLockFile {
        let directoryDescriptor = try openVerifiedDirectory()
        do {
            let lockFileDescriptor = try openVerifiedLockFile(
                in: directoryDescriptor
            )
            return OpenedLockFile(
                directoryDescriptor: directoryDescriptor,
                lockFileDescriptor: lockFileDescriptor
            )
        } catch {
            _ = close(directoryDescriptor)
            throw error
        }
    }

    private func openVerifiedLockFile(
        in directoryDescriptor: Int32
    ) throws -> Int32 {
        let creationFlags =
            O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        var descriptor = openat(
            directoryDescriptor,
            Self.lockFileName,
            creationFlags,
            mode_t(0o600)
        )
        var created = descriptor >= 0

        if descriptor < 0 {
            let creationError = errno
            guard creationError == EEXIST else {
                if creationError == ELOOP {
                    throw AntigravityManagedLaunchCoordinatorError.invalidLockFile
                }
                throw AntigravityManagedLaunchCoordinatorError.posix(
                    function: "openat(create lock)",
                    code: creationError
                )
            }

            descriptor = openat(
                directoryDescriptor,
                Self.lockFileName,
                O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            created = false
        }

        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw AntigravityManagedLaunchCoordinatorError.invalidLockFile
            }
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "openat(lock)",
                code: code
            )
        }

        do {
            if created, fchmod(descriptor, mode_t(0o600)) != 0 {
                throw AntigravityManagedLaunchCoordinatorError.posix(
                    function: "fchmod(lock)",
                    code: errno
                )
            }
            try validateLockFile(descriptor)
            try validateOpenedLockPath(
                descriptor,
                in: directoryDescriptor
            )
            return descriptor
        } catch {
            if created {
                unlinkCreatedLockIfStillSame(
                    descriptor,
                    in: directoryDescriptor
                )
            }
            _ = close(descriptor)
            throw error
        }
    }

    private func validateOpenedPaths(
        _ openedLockFile: OpenedLockFile
    ) throws {
        try validateDirectory(
            openedLockFile.directoryDescriptor
        )
        try validateOpenedDirectoryPath(
            openedLockFile.directoryDescriptor
        )
        try validateLockFile(
            openedLockFile.lockFileDescriptor
        )
        try validateOpenedLockPath(
            openedLockFile.lockFileDescriptor,
            in: openedLockFile.directoryDescriptor
        )
    }

    private func openVerifiedDirectory() throws -> Int32 {
        var metadata = stat()
        if lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw AntigravityManagedLaunchCoordinatorError.posix(
                    function: "lstat(directory)",
                    code: errno
                )
            }

            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                // A concurrent creator is acceptable only when the descriptor
                // checks below prove that the resulting directory is private.
                var racedMetadata = stat()
                guard lstat(directoryURL.path, &racedMetadata) == 0 else {
                    throw error
                }
            }
        }

        let descriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR {
                throw AntigravityManagedLaunchCoordinatorError.invalidDirectory
            }
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "open(directory)",
                code: code
            )
        }

        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw AntigravityManagedLaunchCoordinatorError.posix(
                    function: "fstat(directory before hardening)",
                    code: errno
                )
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AntigravityManagedLaunchCoordinatorError
                    .invalidDirectory
            }
            guard metadata.st_uid == expectedUserID else {
                throw AntigravityManagedLaunchCoordinatorError
                    .invalidDirectoryOwner
            }
            if Self.permissions(metadata.st_mode) != 0o700 {
                guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw AntigravityManagedLaunchCoordinatorError.posix(
                        function: "fchmod(directory)",
                        code: errno
                    )
                }
            }
            try validateDirectory(descriptor)
            try validateOpenedDirectoryPath(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "fstat(directory)",
                code: errno
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw AntigravityManagedLaunchCoordinatorError.invalidDirectory
        }
        guard metadata.st_uid == expectedUserID else {
            throw AntigravityManagedLaunchCoordinatorError.invalidDirectoryOwner
        }
        guard Self.permissions(metadata.st_mode) == 0o700 else {
            throw AntigravityManagedLaunchCoordinatorError
                .invalidDirectoryPermissions
        }
    }

    private func validateOpenedDirectoryPath(
        _ descriptor: Int32
    ) throws {
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "fstat(opened directory)",
                code: errno
            )
        }

        var pathMetadata = stat()
        guard lstat(directoryURL.path, &pathMetadata) == 0 else {
            let code = errno
            if code == ENOENT || code == ELOOP || code == ENOTDIR {
                throw AntigravityManagedLaunchCoordinatorError
                    .invalidDirectory
            }
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "lstat(opened directory path)",
                code: code
            )
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              pathMetadata.st_dev == openedMetadata.st_dev,
              pathMetadata.st_ino == openedMetadata.st_ino
        else {
            throw AntigravityManagedLaunchCoordinatorError
                .invalidDirectory
        }
    }

    private func validateLockFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "fstat(lock)",
                code: errno
            )
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1
        else {
            throw AntigravityManagedLaunchCoordinatorError.invalidLockFile
        }
        guard metadata.st_uid == expectedUserID else {
            throw AntigravityManagedLaunchCoordinatorError.invalidLockFileOwner
        }
        guard Self.permissions(metadata.st_mode) == 0o600 else {
            throw AntigravityManagedLaunchCoordinatorError
                .invalidLockFilePermissions
        }
    }

    private func validateOpenedLockPath(
        _ descriptor: Int32,
        in directoryDescriptor: Int32
    ) throws {
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw AntigravityManagedLaunchCoordinatorError.posix(
                function: "fstat(opened lock)",
                code: errno
            )
        }

        var pathMetadata = stat()
        guard fstatat(
            directoryDescriptor,
            Self.lockFileName,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            throw AntigravityManagedLaunchCoordinatorError.invalidLockFile
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG,
              pathMetadata.st_dev == openedMetadata.st_dev,
              pathMetadata.st_ino == openedMetadata.st_ino
        else {
            throw AntigravityManagedLaunchCoordinatorError.invalidLockFile
        }
    }

    private func unlinkCreatedLockIfStillSame(
        _ descriptor: Int32,
        in directoryDescriptor: Int32
    ) {
        var openedMetadata = stat()
        var pathMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              fstatat(
                  directoryDescriptor,
                  Self.lockFileName,
                  &pathMetadata,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFREG,
              pathMetadata.st_dev == openedMetadata.st_dev,
              pathMetadata.st_ino == openedMetadata.st_ino
        else {
            return
        }
        _ = unlinkat(directoryDescriptor, Self.lockFileName, 0)
    }

    private static func permissions(_ mode: mode_t) -> Int {
        Int(mode & mode_t(0o7777))
    }
}
