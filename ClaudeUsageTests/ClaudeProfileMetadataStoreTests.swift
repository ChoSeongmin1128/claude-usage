import XCTest
@testable import ClaudeUsage

final class ClaudeProfileMetadataStoreTests: XCTestCase {
    func testCredentialPayloadKeepsFieldsLearnedFromProfile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ClaudeProfileMetadataStore(fileURL: file)
        await store.merge(
            ClaudeProfileMetadata(organizationUUID: "org-a", hasExtraUsageEnabled: true, billingType: "stripe"))

        _ = await store.update(from: #"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"max"}}"#)

        let metadata = await store.load()
        XCTAssertEqual(metadata?.subscriptionType, "max")
        XCTAssertEqual(metadata?.hasExtraUsageEnabled, true)
        XCTAssertEqual(metadata?.billingType, "stripe")
    }

    func testAnotherOrganizationReplacesEverything() {
        let current = ClaudeProfileMetadata(organizationUUID: "org-a", subscriptionType: "team", billingType: "invoice")

        let merged = current.merging(ClaudeProfileMetadata(organizationUUID: "org-b", subscriptionType: "pro"))

        XCTAssertEqual(merged.organizationUUID, "org-b")
        XCTAssertEqual(merged.subscriptionType, "pro")
        XCTAssertNil(merged.billingType)
    }

    func testClosingAndSealPreventMetadataWritesAndDeletion() async throws {
        for sealed in [false, true] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                "metadata-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let coordinator = CredentialRecoveryCoordinator.isolated()
            let store = ClaudeProfileMetadataStore(fileURL: file, recoveryCoordinator: coordinator)
            await store.save(ClaudeProfileMetadata(subscriptionType: "pro"))
            let original = try Data(contentsOf: file)
            if sealed { coordinator.sealWrites() } else { coordinator.beginClosing() }

            await store.save(ClaudeProfileMetadata(subscriptionType: "max"))
            await store.clear()
            XCTAssertEqual(try Data(contentsOf: file), original)

            coordinator.abortClosing()
            await store.save(ClaudeProfileMetadata(subscriptionType: "max"))
            let metadata = await store.load()
            XCTAssertEqual(metadata?.subscriptionType, sealed ? "pro" : "max")
        }
    }

    func testInvalidatedReadCannotWriteProfileMetadata() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = CredentialRecoveryCoordinator.isolated()
        let store = ClaudeProfileMetadataStore(fileURL: file, recoveryCoordinator: coordinator)
        let lease = try await coordinator.beginRead()
        coordinator.invalidateReadOperations()
        let result = await store.update(
            from: #"{"claudeAiOauth":{"accessToken":"fixture","subscriptionType":"max"}}"#,
            guardedBy: coordinator, lease: lease)
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
