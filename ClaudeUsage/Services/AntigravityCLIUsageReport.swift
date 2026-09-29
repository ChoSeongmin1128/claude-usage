import Foundation

/// A dotted AGY CLI release number, compared numerically.
nonisolated struct AntigravityCLIVersion:
    Comparable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    /// AGY 1.1.11 added non-interactive answers for `-p "/usage"`. Earlier
    /// releases send the text to the model as a prompt, which spends quota.
    static let minimumUsageReport = Self(major: 1, minor: 1, patch: 11)

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads the first `X.Y.Z` triple from `agy --version` output.
    init?(versionOutput: String) {
        let tokens = versionOutput.split { character in
            !(character.isASCII && (character.isNumber || character == "."))
        }
        for token in tokens {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                let major = Int(parts[0]),
                let minor = Int(parts[1]),
                let patch = Int(parts[2])
            else {
                continue
            }
            self.init(major: major, minor: minor, patch: patch)
            return
        }
        return nil
    }

    var supportsUsageReport: Bool {
        self >= Self.minimumUsageReport
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

nonisolated enum AntigravityCLIUsageReportError: Error, Sendable, Equatable {
    case invalidJSON
    /// The CLI answered with a non-success status.
    case reportFailed
    /// The CLI ran a model turn instead of answering the slash command, so
    /// quota may already have been spent. Callers must not retry automatically.
    case agentTurnStarted
    /// The output is not a usage command result.
    case unexpectedCommand
    case quotaUnavailable(AntigravityQuotaSummaryDecoderError)
}

/// Decodes the stdout of `agy -p /usage --output-format json`.
///
/// The print-mode envelope is described by the AGY changelog, not by a
/// documented schema, so every field that proves a slash-command answer is
/// checked before quota values are read.
nonisolated enum AntigravityCLIUsageReportDecoder {
    static func decode(_ data: Data) throws -> AntigravityDecodedQuotaSummary {
        let rootValue: Any
        do {
            rootValue = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AntigravityCLIUsageReportError.invalidJSON
        }
        guard let root = rootValue as? [String: Any] else {
            throw AntigravityCLIUsageReportError.invalidJSON
        }

        if positiveCount(root["num_turns"]) {
            throw AntigravityCLIUsageReportError.agentTurnStarted
        }
        if let usage = root["usage"] as? [String: Any],
            positiveCount(usage["total_tokens"])
        {
            throw AntigravityCLIUsageReportError.agentTurnStarted
        }

        guard let status = root["status"] as? String else {
            throw AntigravityCLIUsageReportError.unexpectedCommand
        }
        guard status == "SUCCESS" else {
            throw AntigravityCLIUsageReportError.reportFailed
        }

        guard let command = root["command"] as? [String: Any],
            command["name"] as? String == "usage",
            let payload = command["data"] as? [String: Any]
        else {
            throw AntigravityCLIUsageReportError.unexpectedCommand
        }

        do {
            return try AntigravityQuotaSummaryDecoder.decode(payload: payload)
        } catch let error as AntigravityQuotaSummaryDecoderError {
            throw AntigravityCLIUsageReportError.quotaUnavailable(error)
        }
    }

    private static func positiveCount(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return false
        }
        return number.doubleValue > 0
    }
}
