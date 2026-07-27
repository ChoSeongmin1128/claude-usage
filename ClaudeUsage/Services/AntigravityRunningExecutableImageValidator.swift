import Darwin
import Foundation

/// Validates the vnode that macOS actually mapped as a process executable.
///
/// `proc_pidpath` alone is only a path observation. Another process can swap
/// that path between validation and `posix_spawn`, then restore it before a
/// later path check. Production trust decisions therefore compare the
/// executable VM mapping's kernel vnode metadata with the vnode that was
/// hashed into the executable catalog.
nonisolated protocol AntigravityRunningExecutableImageValidating:
    Sendable
{
    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool
}

nonisolated struct AntigravitySystemRunningExecutableImageValidator:
    AntigravityRunningExecutableImageValidating
{
    private static let executableProtection = UInt32(0x4)
    private static let maximumRegionCount = 65_536

    func validatesRunningImage(
        processID: Int32,
        executable: AntigravityCanonicalExecutable
    ) -> Bool {
        guard processID > 0,
              let expected = executable.fileIdentity,
              let pathBefore = executablePath(for: processID),
              pathBefore
                == executable.canonicalURL.standardizedFileURL.path,
              let observed = mappedExecutableVnode(
                  processID: processID,
                  executablePath: pathBefore
              ),
              let pathAfter = executablePath(for: processID),
              pathBefore == pathAfter else {
            return false
        }

        return observed.matches(expected)
    }

    private func executablePath(
        for processID: Int32
    ) -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let result = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(
                processID,
                $0.baseAddress,
                UInt32($0.count)
            )
        }
        guard result > 0 else {
            return nil
        }
        let path = String(cString: buffer)
        guard path.first == "/" else {
            return nil
        }
        // Do not resolve symlinks here. That would consult the mutable current
        // filesystem path instead of describing the image held by the process.
        return URL(fileURLWithPath: path)
            .standardizedFileURL.path
    }

    private func mappedExecutableVnode(
        processID: Int32,
        executablePath: String
    ) -> AntigravityRunningExecutableVnode? {
        var address: UInt64 = 0
        var observedVnodes =
            Set<AntigravityRunningExecutableVnode>()

        for _ in 0..<Self.maximumRegionCount {
            var region = proc_regionwithpathinfo()
            let result = withUnsafeMutablePointer(
                to: &region
            ) {
                proc_pidinfo(
                    processID,
                    PROC_PIDREGIONPATHINFO,
                    address,
                    $0,
                    Int32(
                        MemoryLayout<
                            proc_regionwithpathinfo
                        >.size
                    )
                )
            }

            if result == 0 {
                return observedVnodes.count == 1
                    ? observedVnodes.first
                    : nil
            }
            guard result
                    == MemoryLayout<
                        proc_regionwithpathinfo
                    >.size else {
                return nil
            }

            let info = region.prp_prinfo
            let nextAddress = info.pri_address
                .addingReportingOverflow(info.pri_size)
            guard !nextAddress.overflow,
                  nextAddress.partialValue > address else {
                return nil
            }
            address = nextAddress.partialValue

            guard info.pri_protection
                    & Self.executableProtection != 0,
                  let regionPath = path(
                      from: region.prp_vip
                  ),
                  regionPath == executablePath,
                  let vnode = AntigravityRunningExecutableVnode(
                      region.prp_vip.vip_vi.vi_stat
                  ) else {
                continue
            }
            observedVnodes.insert(vnode)
            guard observedVnodes.count == 1 else {
                // Multiple distinct executable vnodes claiming the process
                // image path are ambiguous and must never be accepted.
                return nil
            }
        }

        // A malicious or malformed process with an excessive region count is
        // not a trustworthy discovery/launch target.
        return nil
    }

    private func path(
        from vnodePath: vnode_info_path
    ) -> String? {
        var vnodePath = vnodePath
        let rawPath = withUnsafePointer(
            to: &vnodePath.vip_path
        ) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: Int(MAXPATHLEN)
            ) {
                String(cString: $0)
            }
        }
        guard rawPath.first == "/" else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
            .standardizedFileURL.path
    }
}

private nonisolated struct AntigravityRunningExecutableVnode:
    Hashable
{
    let deviceID: UInt64
    let inode: UInt64
    let fileSize: UInt64
    let changeTimeSeconds: Int64
    let changeTimeNanoseconds: Int64

    init?(_ status: vinfo_stat) {
        let mode = mode_t(status.vst_mode)
        let ownerIsTrusted =
            status.vst_uid == geteuid()
                || status.vst_uid == 0
        guard (mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (mode & mode_t(0o111)) != 0,
              ownerIsTrusted,
              (mode & mode_t(0o022)) == 0,
              status.vst_nlink == 1,
              status.vst_ino > 0,
              status.vst_size >= 0,
              status.vst_ctime >= 0,
              (0..<1_000_000_000).contains(
                  status.vst_ctimensec
              ) else {
            return nil
        }

        deviceID = UInt64(
            bitPattern: Int64(
                Int32(bitPattern: status.vst_dev)
            )
        )
        inode = status.vst_ino
        fileSize = UInt64(status.vst_size)
        changeTimeSeconds = status.vst_ctime
        changeTimeNanoseconds = status.vst_ctimensec
    }

    func matches(
        _ expected: AntigravityExecutableFileIdentity
    ) -> Bool {
        deviceID == expected.deviceID
            && inode == expected.inode
            && fileSize == expected.fileSize
            && changeTimeSeconds
                == expected.changeTimeSeconds
            && changeTimeNanoseconds
                == expected.changeTimeNanoseconds
    }
}
