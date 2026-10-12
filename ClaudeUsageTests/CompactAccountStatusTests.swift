import AppKit
import SwiftUI
import Vision
import XCTest
@testable import ClaudeUsage

@MainActor
final class CompactAccountStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCurrentKeepsOneRowAndRetainsConfirmationForAccessibility() {
        let presentation = status(.current, age: 720)
        XCTAssertNil(presentation.compactText)
        XCTAssertNil(presentation.generalText(hasUsage: true))
        XCTAssertEqual(
            presentation.accountAccessibilityLabel(name: "Sample account"),
            "Sample account, 현재 값, 마지막 성공 확인 12분 전")
    }

    func testStaleAndArchivedShareStateAndAgeAcrossDensities() {
        for (state, expected) in [
            (UsageAccountState.Status.stale, "이전 값 / 12분 전"),
            (.archived, "보관 / 12분 전"),
        ] {
            let presentation = status(state, age: 720)
            XCTAssertEqual(presentation.compactText, expected)
            XCTAssertEqual(presentation.generalText(hasUsage: true), expected)
            XCTAssertEqual(presentation.generalText(hasUsage: false), expected)
        }
    }

    func testAgeRetainsExistingElapsedFormattingBoundaries() {
        for (age, expected) in [
            (0.0, "방금"), (59, "방금"), (60, "1분 전"), (3_599, "59분 전"),
            (3_600, "1시간 전"), (86_399, "23시간 전"), (86_400, "1일 전"),
        ] {
            XCTAssertEqual(status(.stale, age: age).lastSuccessAge, expected)
        }
        XCTAssertEqual(status(.stale, age: -60).lastSuccessAge, "방금")
    }

    func testMissingOrInvalidConfirmationDoesNotInventAge() {
        let dates: [Date?] = [
            nil, Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
            Date.distantPast.addingTimeInterval(-1),
        ]
        for date in dates {
            for (state, label) in [(UsageAccountState.Status.stale, "이전 값"), (.archived, "보관")] {
                let presentation = OtherAccountStatusPresentation(status: state, fetchedAt: date, now: now)
                XCTAssertNil(presentation.lastSuccessAge)
                XCTAssertEqual(presentation.compactText, label)
                XCTAssertEqual(presentation.accessibilityState, "\(label), 마지막 성공 확인 시각 미확인")
            }
        }
        let invalidClock = OtherAccountStatusPresentation(
            status: .stale, fetchedAt: now, now: Date(timeIntervalSince1970: .nan))
        XCTAssertNil(invalidClock.lastSuccessAge)
    }

    func testQuotaAccessibilityRetainsFullNameWindowBasisStateAndAge() {
        let window = UsageAccountUsage.Window(usedPercent: 32, resetsAt: nil)
        let name = "Long sample account name that may truncate visually"
        for (state, label) in [
            (UsageAccountState.Status.current, "현재 값"), (.stale, "이전 값"), (.archived, "보관"),
        ] {
            let presentation = status(state, age: 720)
            XCTAssertEqual(
                presentation.quotaAccessibilityLabel(
                    accountName: name, label: "5시간", window: window, basis: .remaining),
                "\(name), 5시간 68퍼센트 남음, \(label), 마지막 성공 확인 12분 전")
            XCTAssertEqual(
                presentation.quotaAccessibilityLabel(accountName: name, label: "주간", window: window, basis: .used),
                "\(name), 주간 32퍼센트 사용, \(label), 마지막 성공 확인 12분 전")
        }
    }

    func testMissingQuotaAccessibilityDoesNotInventZeroUsage() {
        let presentation = OtherAccountStatusPresentation(status: .archived, fetchedAt: nil, now: now)
        XCTAssertEqual(
            presentation.quotaAccessibilityLabel(accountName: "Sample", label: "주간", window: nil, basis: .remaining),
            "Sample, 주간 데이터 없음, 보관, 마지막 성공 확인 시각 미확인")
    }

    func testExistingActionAndFailureStatesDoNotAddCompactMetadata() {
        for state in [
            UsageAccountState.Status.loginExpired, .needsPermission, .checking, .failed, .executableNotFound,
        ] {
            XCTAssertNil(status(state, age: 720).compactText)
        }
        XCTAssertEqual(status(.loginExpired, age: 720).generalText(hasUsage: true), "로그인 만료")
        XCTAssertNil(status(.needsPermission, age: 720).generalText(hasUsage: true))
        XCTAssertNil(status(.executableNotFound, age: 720).generalText(hasUsage: false))
        XCTAssertEqual(status(.executableNotFound, age: 720).generalText(hasUsage: true), "Claude Code 없음")
    }

    func testOffscreenActualRowsPreserveStateAndQuotaValuesInBothAppearances() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".work/review-proof/ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fetchedAt = Date().addingTimeInterval(-720)
        let surfaces: [(PopoverDensity, String)] = [(.compact, "compact"), (.standard, "standard")]
        let states: [(UsageAccountState.Status, String, String?)] = [
            (.current, "current", nil), (.stale, "stale", "이전 값"), (.archived, "archived", "보관"),
        ]

        for scheme in [ColorScheme.light, .dark] {
            for (density, surface) in surfaces {
                var currentHeight: CGFloat?
                for (state, name, marker) in states {
                    let data = fixture(state: state, fetchedAt: fetchedAt)
                    let result = try render(data: data, density: density, scheme: scheme)
                    let appearance = scheme == .light ? "light" : "dark"
                    let filename = "r5-fixed-\(surface)-\(name)-\(appearance).png"
                    let bitmap = NSBitmapImageRep(cgImage: result.pixels)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent(filename), options: .atomic)
                    attach(result.image, name: filename)
                    let ocr = try recognize(result.pixels)
                    let text = Self.normalized(ocr)
                    let transcript = XCTAttachment(data: Data(ocr.utf8), uniformTypeIdentifier: "public.plain-text")
                    transcript.name = "\(filename) OCR"
                    transcript.lifetime = .keepAlways
                    add(transcript)

                    XCTAssertTrue(text.contains("68") && text.contains("82"), "\(filename): \(ocr)")
                    let insets =
                        density.isCompact
                        ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets
                    XCTAssertEqual(
                        result.image.size.width,
                        density.isCompact
                            ? PopoverLayoutMetrics.compactPopoverWidth
                            : PopoverLayoutMetrics.standardPopoverWidth,
                        accuracy: 0.5)
                    if let marker {
                        XCTAssertTrue(text.contains(Self.normalized(marker)), "\(filename): \(ocr)")
                        XCTAssertTrue(text.contains("분전"), "The last-success age must remain visible: \(ocr)")
                        if density.isCompact {
                            XCTAssertGreaterThan(result.image.size.height, try XCTUnwrap(currentHeight))
                        }
                    } else {
                        currentHeight = result.image.size.height
                        XCTAssertFalse(text.contains("이전값") || text.contains("보관"), "\(filename): \(ocr)")
                        if density.isCompact {
                            XCTAssertLessThanOrEqual(
                                result.image.size.height,
                                PopoverLayoutMetrics.compactUsageRowHeight + insets.top + insets.bottom)
                        }
                    }
                }
            }
        }
    }

    func testOffscreenNativeAXKeepsAccountAndQuotaStateIndependentlyAccessible() async throws {
        try await requireOffscreenNativeAX()
        let states: [(UsageAccountState.Status, String)] = [
            (.current, "현재 값"), (.stale, "이전 값"), (.archived, "보관"),
        ]
        for density in [PopoverDensity.compact, .standard] {
            for (state, label) in states {
                let data = fixture(state: state, fetchedAt: Date().addingTimeInterval(-720))
                let window = nativeAXWindow(content: nativeAXRow(data: data, density: density))
                defer { window.contentView = nil; window.close() }
                await Task.yield()
                let nodes = nativeAXSnapshot(try XCTUnwrap(window.contentView))
                attachNativeAX(nodes, name: "R5 native AX \(density) \(label)")
                let readable = nodes.filter(\.isElement)
                let name = try XCTUnwrap(
                    readable.first {
                        $0.text.contains(data.name) && !$0.text.contains("5시간") && !$0.text.contains("주간")
                    }, "Account identity must remain its own accessible element.")
                let fiveHour = try XCTUnwrap(
                    readable.first {
                        $0.text.contains("5시간") && !$0.text.contains("주간") && $0.text.contains("68퍼센트 남음")
                    }, "The five-hour quota must not merge with the weekly quota.")
                let weekly = try XCTUnwrap(
                    readable.first {
                        $0.text.contains("주간") && !$0.text.contains("5시간") && $0.text.contains("82퍼센트 남음")
                    }, "The weekly quota must remain independently accessible.")
                XCTAssertEqual(Set([name.id, fiveHour.id, weekly.id]).count, 3)
                for node in [name, fiveHour, weekly] {
                    XCTAssertTrue(node.text.contains(data.name))
                    XCTAssertTrue(node.text.contains(label))
                    XCTAssertTrue(node.text.contains("마지막 성공 확인"))
                    XCTAssertTrue(Self.normalized(node.text).contains("분전"))
                }
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    func testOffscreenNativeAXReconnectAndAllowKeepIndependentInjectedActions() async throws {
        try await requireOffscreenNativeAX()
        let cases: [(UsageAccountState.Status, String, String)] = [
            (.loginExpired, "다시 로그인", "로그인 만료"),
            (.needsPermission, "허용", "허용 필요"),
        ]
        for density in [PopoverDensity.compact, .standard] {
            for (state, buttonTitle, stateLabel) in cases {
                let data = fixture(state: state, fetchedAt: Date().addingTimeInterval(-720))
                let invoked = expectation(description: "Injected \(buttonTitle) action")
                invoked.assertForOverFulfill = true
                var reconnect: [String] = []
                var allow: [String] = []
                let actions = PopoverAccountActions(
                    toggle: { _, _ in XCTFail("An AX button press must not toggle the selected account.") },
                    reconnect: { service, id in
                        reconnect.append("\(service.rawValue)/\(id)"); invoked.fulfill()
                    },
                    allow: { service, id in
                        allow.append("\(service.rawValue)/\(id)"); invoked.fulfill()
                    })
                let content = nativeAXRow(data: data, density: density)
                    .environment(\.popoverAccountActions, actions)
                let window = nativeAXWindow(content: content)
                defer { window.contentView = nil; window.close() }
                await Task.yield()
                let nodes = nativeAXSnapshot(try XCTUnwrap(window.contentView))
                attachNativeAX(nodes, name: "R5 native AX \(density) \(buttonTitle)")
                let readable = nodes.filter(\.isElement)
                let identity = try XCTUnwrap(
                    readable.first {
                        $0.role != .button && $0.text.contains(data.name) && $0.text.contains(stateLabel)
                    })
                let buttons = readable.filter { $0.role == .button }
                XCTAssertEqual(buttons.count, 1, "The actionable row must expose one independent button.")
                let button = try XCTUnwrap(buttons.first { $0.text.contains(buttonTitle) })
                XCTAssertNotEqual(identity.id, button.id)
                XCTAssertTrue(button.isEnabled)
                // This calls only the injected callback through the native AX action, without input events.
                let pressed = button.press()
                XCTAssertTrue(pressed)
                guard pressed else { continue }
                await fulfillment(of: [invoked], timeout: 1)
                let expected = ["\(data.service.rawValue)/\(data.id)"]
                XCTAssertEqual(reconnect, state == .loginExpired ? expected : [])
                XCTAssertEqual(allow, state == .needsPermission ? expected : [])
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    @MainActor private struct NativeAXNode {
        let id: ObjectIdentifier
        let role: NSAccessibility.Role?
        let text: String
        let isElement: Bool
        let isEnabled: Bool
        let children: [Any]
        let press: @MainActor () -> Bool
    }

    private func nativeAXRow(data: PopoverAccountRowData, density: PopoverDensity) -> some View {
        let width =
            density.isCompact
            ? PopoverLayoutMetrics.compactPopoverWidth : PopoverLayoutMetrics.standardPopoverWidth
        let insets =
            density.isCompact
            ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets
        return OtherAccountRow(data: data, density: density)
            .frame(width: width - insets.leading - insets.trailing)
            .padding(insets)
            .environment(\.colorScheme, .light)
    }

    private func nativeAXWindow<Content: View>(content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PopoverLayoutMetrics.standardPopoverWidth, height: 120),
            styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible, "The native AX fixture must never order its window.")
        XCTAssertFalse(window.isKeyWindow)
        return window
    }

    private func requireOffscreenNativeAX() async throws {
        let content = VStack {
            Text("R5 AX probe text")
            Button("R5 AX probe button") {}
        }
        .frame(width: PopoverLayoutMetrics.standardPopoverWidth)
        let window = nativeAXWindow(content: content)
        defer { window.contentView = nil; window.close() }
        await Task.yield()
        let nodes = nativeAXSnapshot(try XCTUnwrap(window.contentView))
        attachNativeAX(nodes, name: "R5 native AX positive control, not VoiceOver")
        let hasText = nodes.contains { $0.isElement && $0.text.contains("R5 AX probe text") }
        let hasButton = nodes.contains { $0.isElement && $0.role == .button && $0.text.contains("R5 AX probe button") }
        guard hasText && hasButton else {
            throw XCTSkip("Offscreen SwiftUI native AX control is unavailable. AX/VoiceOver remains unverified.")
        }
    }

    private func nativeAXSnapshot(_ root: NSView) -> [NativeAXNode] {
        var visited: Set<ObjectIdentifier> = []
        var nodes: [NativeAXNode] = []
        func visit(_ object: AnyObject, depth: Int) {
            guard depth < 16, visited.count < 256, visited.insert(ObjectIdentifier(object)).inserted else { return }
            let node: NativeAXNode
            if let view = object as? NSView {
                node = NativeAXNode(
                    id: ObjectIdentifier(view), role: view.accessibilityRole(),
                    text: [
                        view.accessibilityLabel(), view.accessibilityValue() as? String,
                        view.accessibilityHelp(),
                    ].compactMap { $0 }.joined(separator: ", "),
                    isElement: view.isAccessibilityElement(), isEnabled: view.isAccessibilityEnabled(),
                    children: view.accessibilityChildren() ?? [], press: { view.accessibilityPerformPress() })
            } else if let element = object as? NSAccessibilityElement {
                node = NativeAXNode(
                    id: ObjectIdentifier(element), role: element.accessibilityRole(),
                    text: [
                        element.accessibilityLabel(), element.accessibilityValue() as? String,
                        element.accessibilityHelp(),
                    ].compactMap { $0 }.joined(separator: ", "),
                    isElement: element.isAccessibilityElement(), isEnabled: element.isAccessibilityEnabled(),
                    children: element.accessibilityChildren() ?? [], press: { element.accessibilityPerformPress() })
            } else if let element = object as? any NSAccessibilityProtocol {
                node = NativeAXNode(
                    id: ObjectIdentifier(object), role: element.accessibilityRole(),
                    text: [
                        element.accessibilityLabel(), element.accessibilityValue() as? String,
                        element.accessibilityHelp(),
                    ].compactMap { $0 }.joined(separator: ", "),
                    isElement: element.isAccessibilityElement(), isEnabled: element.isAccessibilityEnabled(),
                    children: element.accessibilityChildren() ?? [], press: { element.accessibilityPerformPress() })
            } else {
                return
            }
            nodes.append(node)
            for child in node.children { visit(child as AnyObject, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return nodes
    }

    private func attachNativeAX(_ nodes: [NativeAXNode], name: String) {
        let text =
            "Automatic in-process native AX only. Actual VoiceOver was not exercised.\n"
            + nodes.map {
                "\($0.id) role=\($0.role?.rawValue ?? "nil") element=\($0.isElement) enabled=\($0.isEnabled) \($0.text)"
            }.joined(separator: "\n")
        let attachment = XCTAttachment(data: Data(text.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func status(_ status: UsageAccountState.Status, age: TimeInterval) -> OtherAccountStatusPresentation {
        OtherAccountStatusPresentation(status: status, fetchedAt: now.addingTimeInterval(-age), now: now)
    }

    private func fixture(state: UsageAccountState.Status, fetchedAt: Date) -> PopoverAccountRowData {
        PopoverAccountRowData(
            id: "r5-fixed-fixture", service: .claude, name: "R5 SAMPLE", badges: [], status: state,
            usage: UsageAccountUsage(
                fiveHour: .init(usedPercent: 32, resetsAt: nil), weekly: .init(usedPercent: 18, resetsAt: nil)),
            fetchedAt: fetchedAt, isRuntime: false, basis: .remaining)
    }

    private func render(
        data: PopoverAccountRowData, density: PopoverDensity, scheme: ColorScheme
    ) throws -> (image: NSImage, pixels: CGImage) {
        let width =
            density.isCompact
            ? PopoverLayoutMetrics.compactPopoverWidth : PopoverLayoutMetrics.standardPopoverWidth
        let insets =
            density.isCompact
            ? PopoverLayoutMetrics.compactBodyInsets : PopoverLayoutMetrics.standardBodyInsets
        let content = OtherAccountRow(data: data, density: density)
            .frame(width: width - insets.leading - insets.trailing)
            .padding(insets)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        var pixels: CGImage?
        appearance.performAsCurrentDrawingAppearance { pixels = renderer.cgImage }
        let rendered = try XCTUnwrap(pixels)
        let size = NSSize(
            width: CGFloat(rendered.width) / renderer.scale,
            height: CGFloat(rendered.height) / renderer.scale)
        return (NSImage(cgImage: rendered, size: size), rendered)
    }

    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func attach(_ image: NSImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    nonisolated private static func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace }).lowercased()
    }
}
