import CoreFoundation
import Foundation

nonisolated enum MenuBarHoverDelay {
    static let key = AppIdentifiers.defaultsKey("menuBarHoverDelay")
    static let range: ClosedRange<TimeInterval> = 0.1...1.0
    static let step: TimeInterval = 0.1
    static let defaultValue: TimeInterval = range.lowerBound

    static func normalized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultValue }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return min(max((clamped / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    static func load(from defaults: UserDefaults) -> TimeInterval {
        guard let number = defaults.object(forKey: key) as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return defaultValue }
        return normalized(number.doubleValue)
    }
}
