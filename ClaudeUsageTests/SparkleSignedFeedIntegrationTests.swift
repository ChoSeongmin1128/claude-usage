import CryptoKit
import Foundation
import Network
import Sparkle
import XCTest

/// Exercises the shipped Sparkle framework through its public updater API.
/// A headless driver cancels before archive download; no app or window launches.
@MainActor
final class SparkleSignedFeedIntegrationTests: XCTestCase {
    func testValidSignedFeedPreservesEmbeddedNotes() async throws {
        let result = try await checkFeed(tampered: false, expired: false)
        XCTAssertNotNil(result.item)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.item?.itemDescription, "Approved release notes")
    }

    func testModifiedFeedIsRejectedBeforeShowingAnUpdate() async throws {
        let result = try await checkFeed(tampered: true, expired: false)
        XCTAssertNil(result.item)
        XCTAssertTrue(isSignatureFailure(result.error))
    }

    func testExpiredSignatureFailureOffersRecoveryWithoutUntrustedNotes() async throws {
        let result = try await checkFeed(tampered: true, expired: true)
        XCTAssertNotNil(result.item)
        XCTAssertNil(result.item?.itemDescription)
        XCTAssertNil(result.item?.releaseNotesURL)
    }

    func testFeedKeyRotationRequiresRecoveryBeforeAcceptingTheNewKey() async throws {
        let oldKey = Curve25519.Signing.PrivateKey()
        let newKey = Curve25519.Signing.PrivateKey()
        let blocked = try await checkFeed(tampered: false, expired: false, hostKey: oldKey, feedKey: newKey)
        XCTAssertNil(blocked.item)
        XCTAssertTrue(isSignatureFailure(blocked.error))
        let recovery = try await checkFeed(tampered: false, expired: true, hostKey: oldKey, feedKey: newKey)
        XCTAssertNotNil(recovery.item)
        XCTAssertNil(recovery.item?.itemDescription)
        let accepted = try await checkFeed(tampered: false, expired: false, hostKey: newKey, feedKey: newKey)
        XCTAssertNotNil(accepted.item)
        XCTAssertEqual(accepted.item?.itemDescription, "Approved release notes")
    }

    private func isSignatureFailure(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == SUSparkleErrorDomain && error.code == 3002 { return true }
        return isSignatureFailure(error.userInfo[NSUnderlyingErrorKey] as? Error)
    }

    private func checkFeed(tampered: Bool, expired: Bool,
                           hostKey: Curve25519.Signing.PrivateKey? = nil,
                           feedKey: Curve25519.Signing.PrivateKey? = nil) async throws -> FeedUserDriver {
        let identifier = "test.ClaudeUsage.signed-feed." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let signingKey = hostKey ?? Curve25519.Signing.PrivateKey()
        let server = try FeedHTTPServer()
        defer { server.stop() }
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)/appcast.xml")!
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleName": "Feed Fixture",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "SUFeedURL": url.absoluteString,
            "SUPublicEDKey": signingKey.publicKey.rawRepresentation.base64EncodedString(),
            "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false,
            "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
            "SUSignedFeedFailureExpirationInterval": 1_728_000,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // Sparkle 2.10 records external-host failures in the test process's
        // domain with this host-specific suffix. Only this UUID key is touched.
        let failureKey = "SUInitialFailedFeedSigningValidationDate_" + identifier
        defer {
            UserDefaults.standard.removeObject(forKey: failureKey)
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        if expired {
            UserDefaults.standard.set(Date().addingTimeInterval(-1_728_001), forKey: failureKey)
        }
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><title>Fixture</title><sparkle:version>2</sparkle:version>
          <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
          <description sparkle:format="plain-text">Approved release notes</description>
          <enclosure url="https://example.test/ClaudeUsage.dmg" length="1" type="application/octet-stream"
          sparkle:edSignature="\(Data(repeating: 0, count: 64).base64EncodedString())" />
          </item></channel>
        </rss>
        """.utf8)
        let signature = try (feedKey ?? signingKey).signature(for: body).base64EncodedString()
        let content = tampered ? Data(String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "Approved", with: "Tampered").utf8) : body
        let trailer = Data("<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(body.count)\n-->\n".utf8)
        server.setResponse(content + trailer)
        let completed = expectation(description: "Sparkle feed validation completed")
        let driver = FeedUserDriver(completed: completed)
        let bundle = try XCTUnwrap(Bundle(url: root))
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: driver)
        try updater.start()
        updater.checkForUpdates()
        await fulfillment(of: [completed], timeout: 10)
        // Retain the updater until its terminal callback, preventing cancellation
        // from masquerading as a successful signature rejection.
        withExtendedLifetime(updater) {}
        return driver
    }
}

@MainActor
private final class FeedUserDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    let completed: XCTestExpectation
    var item: SUAppcastItem?
    var error: Error?
    init(completed: XCTestExpectation) { self.completed = completed }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        XCTFail("Feed validation must not ask for permissions")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.item = item
        reply(.dismiss)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { XCTFail("Expected embedded notes") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.error = error; acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        self.error = error; acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { cancellation(); XCTFail("Archive download is outside this fixture") }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { XCTFail("Fixture must never install") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.dismiss) }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        completed.fulfill()
    }
}

private final class FeedHTTPServer: @unchecked Sendable {
    // Response bytes cross the XCTest/main and Network callback queues only
    // through this lock. NWListener and NWConnection own their synchronization.
    private let lock = NSLock()
    private var response = Data()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.ClaudeUsage.signed-feed")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func setResponse(_ data: Data) { lock.withLock { response = data } }
    func stop() { listener.newConnectionHandler = nil; listener.cancel() }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let data = lock.withLock { response }
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}
