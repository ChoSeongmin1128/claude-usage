import Foundation

/// Blocking interactions emitted by the AGY CLI.
///
/// The managed session may surface these states to the user, but it must never
/// answer any of them on the user's behalf.
nonisolated enum AntigravityManagedCLIInteraction:
    String,
    CaseIterable,
    Hashable,
    Sendable
{
    case loginRequired
    case projectTrustRequired
    case browserAuthenticationRequired
}

/// Classifies only blocking AGY interactions from a bounded rolling window.
///
/// This type intentionally exposes neither the raw PTY bytes nor normalized
/// terminal text. Callers receive typed interaction states only, which keeps
/// credentials, URLs, and other terminal content out of logs and diagnostics.
nonisolated struct AntigravityManagedCLIOutputClassifier: Sendable {
    static let maximumBufferedBytes = 16 * 1_024

    private var recentOutput = Data()
    private(set) var interactions: Set<AntigravityManagedCLIInteraction> = []
    private(set) var outputWasTruncated = false
    private(set) var announcedLocalServerPort:
        AntigravityTCPPort?

    /// Ingests PTY bytes and returns interactions first observed by this call.
    ///
    /// `interactions` remains cumulative for the lifetime of the classifier so
    /// a cursor rewrite cannot make an already-observed blocking prompt vanish.
    mutating func ingest(_ data: Data) -> Set<AntigravityManagedCLIInteraction> {
        guard !data.isEmpty else { return [] }

        if data.count >= Self.maximumBufferedBytes {
            if data.count > Self.maximumBufferedBytes
                || !recentOutput.isEmpty
            {
                outputWasTruncated = true
            }
            recentOutput = Data(data.suffix(Self.maximumBufferedBytes))
        } else {
            recentOutput.append(data)
            if recentOutput.count > Self.maximumBufferedBytes {
                outputWasTruncated = true
                recentOutput.removeFirst(
                    recentOutput.count - Self.maximumBufferedBytes
                )
            }
        }

        let normalized =
            Self.normalizedTerminalText(
                from: recentOutput
            )
        if let port =
                Self.localServerPort(
                    in: normalized
                )
        {
            announcedLocalServerPort =
                port
        }
        let detected = Self.classify(normalized)
        let newlyObserved = detected.subtracting(interactions)
        interactions.formUnion(detected)
        return newlyObserved
    }

    private static func classify(
        _ text: String
    ) -> Set<AntigravityManagedCLIInteraction> {
        guard !text.isEmpty else { return [] }

        var result: Set<AntigravityManagedCLIInteraction> = []
        let flattenedText = text.replacingOccurrences(
            of: "\n",
            with: " "
        )

        // A transient "not signed in" status is not sufficient. AGY can print
        // it while silently refreshing a still-valid session. These phrases
        // identify a prompt that is actually waiting for user selection.
        if flattenedText.contains("select login method")
            || flattenedText.contains("choose a login method")
            || flattenedText.contains("choose your login method")
            || flattenedText.contains("how would you like to sign in")
            || flattenedText.contains("press enter to sign in")
        {
            result.insert(.loginRequired)
        }

        let hasTrustSubject = [
            "project",
            "folder",
            "workspace",
            "directory",
            "authors",
        ].contains(where: flattenedText.contains)
        let hasBlockingTrustQuestion =
            flattenedText.contains("do you trust")
                || flattenedText.contains("would you like to trust")
                || flattenedText.contains("select whether you trust")
                || flattenedText.contains("trust this project")
                || flattenedText.contains("trust this folder")
                || flattenedText.contains("trust this workspace")
                || flattenedText.contains("trust this directory")
        if hasTrustSubject, hasBlockingTrustQuestion {
            result.insert(.projectTrustRequired)
        }

        // Keep the auth intent and browser action on the same visible line.
        // Otherwise a transient signed-out line followed by an unrelated docs
        // URL can be combined into a false blocking state.
        let hasBlockingBrowserLine = text
            .split(separator: "\n")
            .contains { line in
                let visibleLine = String(line)
                let hasAuthenticationIntent = [
                    "authenticate",
                    "authentication",
                    "authorize",
                    "authorization",
                    "sign in",
                    "login",
                    "log in",
                    "verify",
                ].contains(where: visibleLine.contains)
                let asksForBrowserAction =
                    visibleLine.contains("open your browser")
                        || visibleLine.contains("open the following url")
                        || visibleLine.contains("open this url")
                        || visibleLine.contains("visit the following url")
                        || visibleLine.contains("visit this url")
                        || visibleLine.contains("continue in your browser")
                        || visibleLine.contains("waiting for browser")
                return hasAuthenticationIntent && asksForBrowserAction
            }
        if hasBlockingBrowserLine {
            result.insert(.browserAuthenticationRequired)
        }

        return result
    }

    private static func localServerPort(
        in text: String
    ) -> AntigravityTCPPort? {
        for line in text
            .split(separator: "\n")
            .reversed()
        {
            let normalized =
                line.lowercased()
            if let port = port(
                in: normalized,
                after:
                    "language server listening on random port at ",
                requiredSuffix: " for https (grpc)"
            ) {
                return port
            }
            if let port = port(
                in: normalized,
                after:
                    "local server: https://127.0.0.1:"
            ) {
                return port
            }
        }
        return nil
    }

    private static func port(
        in line: String,
        after marker: String,
        requiredSuffix: String? = nil
    ) -> AntigravityTCPPort? {
        guard let range = line.range(of: marker)
        else {
            return nil
        }
        let tail = line[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty,
              let rawPort = Int(digits),
              let port = AntigravityTCPPort(rawPort)
        else {
            return nil
        }
        if let requiredSuffix {
            let suffix = tail.dropFirst(digits.count)
            guard suffix.hasPrefix(requiredSuffix)
            else {
                return nil
            }
        }
        return port
    }

    /// Removes ANSI CSI/OSC sequences and C0 controls without interpreting the
    /// terminal. OSC payloads are discarded in full because they may contain
    /// titles or URLs that are not visible blocking prompts.
    private static func normalizedTerminalText(from data: Data) -> String {
        enum ParseState {
            case text
            case escape
            case controlSequence
            case operatingSystemCommand
            case operatingSystemCommandEscape
        }

        var state = ParseState.text
        var visible: [UInt8] = []
        visible.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .text:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .controlSequence
                case 0x9D:
                    state = .operatingSystemCommand
                case 0x08, 0x7F:
                    // Remove one complete UTF-8 scalar where possible.
                    while let removed = visible.popLast(),
                          removed & 0xC0 == 0x80
                    {}
                case 0x09:
                    visible.append(0x20)
                case 0x0A, 0x0D:
                    visible.append(0x0A)
                case 0x00...0x1F:
                    visible.append(0x20)
                default:
                    visible.append(byte)
                }

            case .escape:
                switch byte {
                case 0x5B:
                    state = .controlSequence
                case 0x5D:
                    state = .operatingSystemCommand
                default:
                    // Two-byte escape sequences end at this byte.
                    state = .text
                }

            case .controlSequence:
                // ECMA-48 CSI sequences end at a byte in 0x40...0x7E.
                if (0x40...0x7E).contains(byte) {
                    state = .text
                }

            case .operatingSystemCommand:
                if byte == 0x07 {
                    state = .text
                } else if byte == 0x1B {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                state = byte == 0x5C ? .text : .operatingSystemCommand
            }
        }

        let decoded = String(decoding: visible, as: UTF8.self)
        let withoutControls = decoded.unicodeScalars.filter {
            $0.value == 0x0A
                || !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(withoutControls))
            .lowercased()
            .split(separator: "\n")
            .map {
                $0.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
