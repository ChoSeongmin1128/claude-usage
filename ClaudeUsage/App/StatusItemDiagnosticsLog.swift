import Foundation

/// 메뉴바 전용 앱의 대표 실패 모드는 "안 보임"이고, 그 상태에서는 사용자가
/// 설정 창조차 열 수 없다. `Logger`는 DEBUG에서만 출력하므로 설치본은 아무
/// 기록도 남기지 않는다. 자격증명이 오가는 일반 로그를 전부 파일로 내리는 대신,
/// 배치 진단에 필요한 항목만 담는 별도 채널을 둔다. 여기에 들어가는 값은
/// 위치/불리언/치수뿐이다.
enum StatusItemDiagnosticsLog {
    nonisolated private static let queue = DispatchQueue(
        label: "claudeusage.status-item-diagnostics",
        qos: .utility
    )
    nonisolated private static let rotateBytes = 256 * 1024

    nonisolated private static let fileURL: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent(AppDistribution.current.applicationSupportDirectoryName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("status-item.log")
    }()

    nonisolated static var path: String { fileURL.path }

    nonisolated static func record(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        queue.async {
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                try? data.write(to: fileURL)
                return
            }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }

    /// 파일 한 줄을 찍기 위한 포맷터를 공유 상태로 들고 있지 않는다. 진단 로그는
    /// 실행당 몇 줄이고, `DateFormatter`는 Sendable이 아니다.
    nonisolated private static func timestamp() -> String {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: Date()
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            (parts.nanosecond ?? 0) / 1_000_000
        )
    }

    nonisolated private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
        guard size > rotateBytes else { return }
        let old = fileURL.deletingLastPathComponent().appendingPathComponent("status-item.log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}
