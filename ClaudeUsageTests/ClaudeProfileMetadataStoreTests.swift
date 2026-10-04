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
}
