import Foundation

/// The product whose current authenticated session supplies usage. Selecting a
/// target never changes that product's login or falls back to another product.
nonisolated enum AntigravityUsageTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case unselected
    case cli
    case app

    var title: String {
        switch self {
        case .unselected: "조회 대상 선택"
        case .cli: "AGY CLI"
        case .app: "Antigravity 독립 앱"
        }
    }
}
