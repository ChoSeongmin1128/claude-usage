import Foundation

struct NotificationPreset: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var threshold: Int
    var isEnabled: Bool

    init(id: String = UUID().uuidString, threshold: Int, isEnabled: Bool = true) {
        self.id = id
        self.threshold = max(1, min(threshold, 100))
        self.isEnabled = isEnabled
    }
}
