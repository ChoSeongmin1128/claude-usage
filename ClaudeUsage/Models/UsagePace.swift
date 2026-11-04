import CoreFoundation
import Foundation

/// A quota window whose reset time and length are both known.
nonisolated struct UsagePaceWindow: Equatable, Sendable {
    let resetAt: Date
    let lengthSeconds: Int

    init?(resetAt: Date?, lengthSeconds: Int?) {
        guard let resetAt, TimeFormatter.validatedResetDate(resetAt) != nil, let lengthSeconds, lengthSeconds > 0
        else { return nil }
        self.resetAt = resetAt
        self.lengthSeconds = lengthSeconds
    }

    init?(resetAtISO: String?, lengthSeconds: Int?) {
        self.init(resetAt: resetAtISO.flatMap(TimeFormatter.parseISO8601), lengthSeconds: lengthSeconds)
    }

    func elapsedFraction(now: Date) -> Double? {
        let length = TimeInterval(lengthSeconds)
        let fraction = (length - resetAt.timeIntervalSince(now)) / length
        // A stale reset or a window that has not started is hidden, not pinned to an end of the bar.
        guard fraction.isFinite, (0...1).contains(fraction) else { return nil }
        return fraction
    }

    func marker(basis: UsageValueBasis, now: Date) -> UsagePaceMarker? {
        elapsedFraction(now: now).map { UsagePaceMarker(elapsedPercentage: $0 * 100, basis: basis) }
    }
}

/// The elapsed share of a window, expressed on the same basis as the usage it sits on.
nonisolated struct UsagePaceMarker: Equatable, Sendable {
    let elapsedPercentage: Double
    let basis: UsageValueBasis

    var displayPercentage: Double { basis.percentage(fromUsed: elapsedPercentage) ?? 0 }

    var title: String { basis == .used ? "경과 시간" : "남은 시간" }

    var text: String { "\(title) \(PercentageText.string(displayPercentage))" }

    var spokenText: String {
        PercentageText.wholeNumber(displayPercentage).map { "\(title) \($0)퍼센트" } ?? title
    }
}

nonisolated enum UsagePaceMarkerPreference {
    static let key = AppIdentifiers.defaultsKey("usagePaceMarker")
    static let defaultValue = true

    static func load(from defaults: UserDefaults) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return defaultValue }
        return number.boolValue
    }
}

extension CodexUsageWindow {
    nonisolated var paceWindow: UsagePaceWindow? {
        UsagePaceWindow(resetAt: resetAt.map(Date.init(timeIntervalSince1970:)), lengthSeconds: limitWindowSeconds)
    }
}

extension UsageLimit {
    nonisolated var paceWindow: UsagePaceWindow? {
        UsagePaceWindow(resetAt: resetAt, lengthSeconds: periodSeconds)
    }
}
