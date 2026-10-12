import CoreFoundation
import Foundation

nonisolated enum CodexWindowDuration {
    static func positiveSeconds(_ seconds: Int) -> Int? {
        seconds > 0 ? seconds : nil
    }

    static func seconds(fromMinutes value: Any) -> Int? {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            let seconds = Int(exactly: number.doubleValue * 60)
        else { return nil }
        return positiveSeconds(seconds)
    }
}
