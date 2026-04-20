import Foundation

enum PopoverGeometryDiagnostics {
    private static let debugFlagKey = "DebugPopoverGeometry"
    private static let environmentKey = "CLAUDEUSAGE_POPOVER_GEOMETRY_DEBUG"
    private static let formatter = ISO8601DateFormatter()

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
            || UserDefaults.standard.bool(forKey: debugFlagKey)
    }

    static var logFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeUsagePopoverGeometry.log")
    }

    static func resetSession(_ header: String) {
        guard isEnabled else { return }
        let banner = "==== \(timestamp()) \(header) ====\n"
        try? banner.write(to: logFileURL, atomically: true, encoding: .utf8)
        Logger.debug("PopoverGeometry session reset: \(header)")
    }

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(timestamp())] \(message)\n"
        Logger.debug(message)

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                return
            }
        }

        try? line.write(to: logFileURL, atomically: true, encoding: .utf8)
    }

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
