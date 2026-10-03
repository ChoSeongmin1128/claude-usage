import XCTest
@testable import ClaudeUsage

final class AntigravitySubprocessSpawnTests: XCTestCase {
    func testQoSClassIsAppliedToSpawnAttributes() {
        XCTAssertEqual(configuredQoS(nil), QOS_CLASS_UNSPECIFIED)
        XCTAssertEqual(configuredQoS(QOS_CLASS_UTILITY), QOS_CLASS_UTILITY)
    }

    func testSpawnSucceedsWithQoSClass() throws {
        let spawned = try XCTUnwrap(
            AntigravitySubprocessSpawn.spawn(
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 7"],
                environment: [:],
                options: .init(qosClass: QOS_CLASS_UTILITY)
            )
        )
        close(spawned.standardOutputFileDescriptor)
        close(spawned.standardErrorFileDescriptor)
        var status: Int32 = 0
        waitpid(spawned.processID, &status, 0)

        XCTAssertEqual((status >> 8) & 0xff, 7)
    }

    private func configuredQoS(_ qosClass: qos_class_t?) -> qos_class_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        XCTAssertTrue(AntigravitySubprocessSpawn.configure(&attributes, .init(qosClass: qosClass)))
        var result = QOS_CLASS_UNSPECIFIED
        posix_spawnattr_get_qos_class_np(&attributes, &result)
        return result
    }
}
