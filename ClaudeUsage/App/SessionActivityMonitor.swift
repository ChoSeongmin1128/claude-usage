import CoreServices
import Foundation

/// 세션 폴더의 변경 알림으로 "지금 쓰는 중"인지 판단한다. 파일 내용은 읽지 않는다.
@MainActor
final class SessionActivityMonitor {
    private var streams: [PopoverService: FSEventStreamRef] = [:]
    private(set) var lastActivityAt: [PopoverService: Date] = [:]
    var onActivity: ((PopoverService) -> Void)?

    static func defaultWatchedDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [PopoverService: URL]
    {
        [
            .claude: home.appendingPathComponent(".claude/projects", isDirectory: true),
            .codex: home.appendingPathComponent(".codex/sessions", isDirectory: true),
        ]
    }

    func start(directories: [PopoverService: URL] = SessionActivityMonitor.defaultWatchedDirectories()) {
        stop()
        for (service, directory) in directories where FileManager.default.fileExists(atPath: directory.path) {
            if let stream = makeStream(service: service, path: directory.path) {
                streams[service] = stream
            }
        }
    }

    func stop() {
        for stream in streams.values {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
    }

    fileprivate func record(_ service: PopoverService) {
        lastActivityAt[service] = Date()
        onActivity?(service)
    }

    private func makeStream(service: PopoverService, path: String) -> FSEventStreamRef? {
        let box = Unmanaged.passRetained(SessionActivityCallbackBox(monitor: self, service: service))
        var context = FSEventStreamContext(
            version: 0, info: box.toOpaque(), retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<SessionActivityCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<SessionActivityCallbackBox>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { box.monitor?.record(box.service) }
        }
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        return stream
    }
}

private final class SessionActivityCallbackBox {
    weak var monitor: SessionActivityMonitor?
    let service: PopoverService

    init(monitor: SessionActivityMonitor, service: PopoverService) {
        self.monitor = monitor
        self.service = service
    }
}
