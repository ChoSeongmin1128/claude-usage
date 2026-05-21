import XCTest
@testable import ClaudeUsage

final class AntigravityRuntimeRefresherTests: XCTestCase {
    func testLocalIDESourceUsesOnlyLocalFetcher() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .localIDE, percent: 12))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .googleOAuth, percent: 88))])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .localIDE
        )

        XCTAssertEqual(usage.source, .localIDE)
        XCTAssertEqual(usage.primaryPercentage, 12)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 0)
    }

    func testGoogleOAuthSourceUsesOnlyRemoteFetcher() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .localIDE, percent: 12))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .googleOAuth, percent: 88))])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .googleOAuth
        )

        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.primaryPercentage, 88)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 0)
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testAutoSourceKeepsLocalResultWhenLocalSucceeds() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .localIDE, percent: 33))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .googleOAuth, percent: 88))])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .auto
        )

        XCTAssertEqual(usage.source, .localIDE)
        XCTAssertEqual(usage.primaryPercentage, 33)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 0)
    }

    func testAutoSourceUsesRemoteWhenLocalSucceedsWithoutQuotaWindows() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.success(Self.identityOnlyUsage(source: .localIDE))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .googleOAuth, percent: 68))])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .auto
        )

        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.primaryPercentage, 68)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testAutoSourceKeepsLocalIdentityOnlyResultWhenRemoteSupplementFails() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.success(Self.identityOnlyUsage(source: .localIDE))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.invalidSessionKey)])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .auto
        )

        XCTAssertEqual(usage.source, .localIDE)
        XCTAssertEqual(usage.accountEmail, "nathan@example.com")
        XCTAssertFalse(usage.hasUsageWindows)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testAutoSourceFallsBackToRemoteWhenLocalFails() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.networkError("local down"))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.success(Self.usage(source: .googleOAuth, percent: 76))])

        let usage = try await AntigravityRuntimeRefresher.refresh(
            apiService: local,
            remoteService: remote,
            dataSource: .auto
        )

        XCTAssertEqual(usage.source, .googleOAuth)
        XCTAssertEqual(usage.primaryPercentage, 76)
        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testAutoSourcePreservesLocalErrorWhenRemoteHasNoCredential() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.networkError("local down"))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.invalidSessionKey)])

        do {
            _ = try await AntigravityRuntimeRefresher.refresh(
                apiService: local,
                remoteService: remote,
                dataSource: .auto
            )
            XCTFail("Expected local error")
        } catch let error as APIError {
            guard case .networkError("local down") = error else {
                return XCTFail("Expected local network error, got \(error)")
            }
        }

        let localCallCount = await local.callCount()
        let remoteCallCount = await remote.callCount()
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(remoteCallCount, 1)
    }

    func testAutoSourceSurfacesRemoteNonCredentialFailure() async throws {
        let local = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.networkError("local down"))])
        let remote = ScriptedAntigravityUsageFetcher(results: [.failure(APIError.permissionDenied("quota denied"))])

        do {
            _ = try await AntigravityRuntimeRefresher.refresh(
                apiService: local,
                remoteService: remote,
                dataSource: .auto
            )
            XCTFail("Expected remote permission error")
        } catch let error as APIError {
            guard case .permissionDenied("quota denied") = error else {
                return XCTFail("Expected remote permission error, got \(error)")
            }
        }
    }

    private static func usage(source: AntigravityUsageDataSource, percent: Double) -> AntigravityUsageResponse {
        AntigravityUsageResponse(
            source: source,
            accountEmail: "nathan@example.com",
            accountPlan: "Paid",
            primaryWindow: AntigravityUsageWindow(
                label: "Claude",
                modelID: "claude-sonnet-4-5",
                usedPercent: percent,
                resetAtISO: nil
            ),
            secondaryWindow: nil,
            tertiaryWindow: nil
        )
    }

    private static func identityOnlyUsage(source: AntigravityUsageDataSource) -> AntigravityUsageResponse {
        AntigravityUsageResponse(
            source: source,
            accountEmail: "nathan@example.com",
            accountPlan: "Paid",
            primaryWindow: nil,
            secondaryWindow: nil,
            tertiaryWindow: nil
        )
    }
}

private actor ScriptedAntigravityUsageFetcher: AntigravityUsageFetching {
    private var results: [Result<AntigravityUsageResponse, Error>]
    private var calls = 0

    init(results: [Result<AntigravityUsageResponse, Error>]) {
        self.results = results
    }

    func fetchUsageForRuntime() async throws -> AntigravityUsageResponse {
        calls += 1
        guard !results.isEmpty else {
            throw APIError.unknownError("No scripted Antigravity result")
        }
        let result = results.removeFirst()
        switch result {
        case .success(let usage):
            return usage
        case .failure(let error):
            throw error
        }
    }

    func callCount() -> Int {
        calls
    }
}
