import SwiftUI

private struct UsagePaceMarkerVisibleKey: EnvironmentKey {
    // A host that does not pass the setting shows no marker rather than one the user turned off.
    static let defaultValue = false
}

extension EnvironmentValues {
    var usagePaceMarkerVisible: Bool {
        get { self[UsagePaceMarkerVisibleKey.self] }
        set { self[UsagePaceMarkerVisibleKey.self] = newValue }
    }
}

extension UsagePaceWindow {
    func visibleMarker(isEnabled: Bool, basis: UsageValueBasis, now: Date = Date()) -> UsagePaceMarker? {
        isEnabled ? marker(basis: basis, now: now) : nil
    }
}

extension Optional where Wrapped == UsagePaceMarker {
    func appending(toTooltip tooltip: String) -> String {
        guard let marker = self else { return tooltip }
        return tooltip + "\n" + marker.text
    }

    func appending(toAccessibilityValue value: String) -> String {
        guard let marker = self else { return value }
        return value + ", " + marker.spokenText
    }
}
