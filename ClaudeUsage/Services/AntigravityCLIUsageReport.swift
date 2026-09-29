import Foundation

nonisolated struct AntigravityCLIVersion:
    Comparable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    // Earlier releases send `-p "/usage"` to the model as a prompt, spending quota.
    static let minimumUsageReport = Self(major: 1, minor: 1, patch: 11)

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

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
    case reportFailed
    case agentTurnStarted
    case unexpectedCommand
    case quotaUnavailable(AntigravityQuotaSummaryDecoderError)
}

// The print-mode envelope has no documented schema, so every field that proves
// a slash-command answer is checked before quota values are read.
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
