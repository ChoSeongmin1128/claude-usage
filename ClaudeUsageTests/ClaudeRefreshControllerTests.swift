import XCTest
@testable import ClaudeUsage

@MainActor
final class ClaudeRefreshControllerTests: XCTestCase {
    func testDiscardedFirstResultIsRetriedWithinTheSameAwaitedTask() async throws {
        let suite = "ClaudeRefreshControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let service = ClaudeAPIService(
            sessionKey: "sk-ant-fixture", cacheStorage: .init(defaults: defaults, profileMetadataDirectory: root),
            httpRunner: { request in
                let url = request.url!
                let body: String
                if url.path.hasSuffix("/organizations") {
                    body = #"[{"uuid":"org"}]"#
                } else if url.path.hasSuffix("/usage") {
                    body = #"{"five_hour":{"utilization":12,"resets_at":null}}"#
                } else {
                    body = "null"
                }
                return (
                    Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let state = HostState()
        let controller = ClaudeRefreshController(
            apiService: service,
            host: .init(
                isEnabled: { true }, prepare: { _ in true },
                beginRequest: { state.begin() },
                currentRequest: { state.current() },
                releaseUnfinishedRequest: { state.release($0) },
                inputs: { .init(lastOverageAttemptAt: nil, overageOwnerKey: nil, knownIdentities: [:]) },
                applySuccess: { _, _, _ in
                    state.successes += 1; state.finished = true
                },
                applyFailure: { error, _, _ in XCTFail("Unexpected \(error)") },
                didReleaseRequest: { state.releases += 1 }))

        await controller.refresh(force: true)?.value

        XCTAssertEqual(state.releases, 1, "The first result was discarded once")
        XCTAssertEqual(state.successes, 1, "The awaited task must include the retry")
    }
}

@MainActor
private final class HostState {
    var successes = 0
    var releases = 0
    var finished = false
    private var revision = UUID()
    private var requests = 0

    func begin() -> UUID {
        requests += 1
        revision = UUID()
        return revision
    }

    /// 첫 요청이 끝날 때는 계정 문맥이 바뀐 것처럼 다른 요청 번호를 돌려준다.
    func current() -> UUID { requests == 1 ? UUID() : revision }

    func release(_ request: UUID) -> Bool {
        guard !finished else { return false }
        return requests == 1
    }
}
