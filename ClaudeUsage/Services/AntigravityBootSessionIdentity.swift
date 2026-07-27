import Darwin
import Foundation

nonisolated protocol AntigravityBootSessionIdentityProviding:
    Sendable
{
    func currentBootSessionID() -> AntigravityBootSessionID?
}

/// Reads the kernel-issued identity for the current macOS boot.
///
/// There is deliberately no `kern.boottime` fallback: a wall-clock value is
/// not a stable boot identity and must not authorize process recovery.
nonisolated struct AntigravitySystemBootSessionIdentityProvider:
    AntigravityBootSessionIdentityProviding
{
    private static let maximumValueBytes = 64

    func currentBootSessionID() -> AntigravityBootSessionID? {
        var byteCount = 0
        guard sysctlbyname(
            "kern.bootsessionuuid",
            nil,
            &byteCount,
            nil,
            0
        ) == 0,
        byteCount > 1,
        byteCount <= Self.maximumValueBytes else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: byteCount)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname(
                "kern.bootsessionuuid",
                bytes.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0,
              byteCount > 1,
              byteCount <= buffer.count else {
            return nil
        }

        let returned = buffer.prefix(byteCount)
        guard let terminator = returned.firstIndex(of: 0),
              terminator == returned.index(before: returned.endIndex),
              let value = String(
                  bytes: returned[..<terminator],
                  encoding: .utf8
              ),
              let uuid = UUID(uuidString: value) else {
            return nil
        }
        return AntigravityBootSessionID(rawValue: uuid)
    }
}
