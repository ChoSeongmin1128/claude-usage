import SwiftUI

enum PopoverDensity: Equatable {
    case compact
    case standard

    var isCompact: Bool {
        self == .compact
    }
}

enum PopoverContentPhase {
    case authRequired
    case loading
    case error
    case empty
    case content
}

enum PopoverSectionImportance: Equatable {
    case primary
    case secondary
}

enum PopoverDisplaySectionKind: Equatable {
    case usage
    case credits
    case overage
    case account
    case status
}

struct PopoverUsageSectionData {
    let systemIcon: String
    let title: String
    let compactLabel: String
    let percentage: Double
    let resetAt: String?
    let isWeekly: Bool
    let timeFormatStyle: TimeFormatStyle
}

struct PopoverCreditsSectionData {
    let credits: CodexCredits
}

struct PopoverOverageSectionData {
    let overage: OverageSpendLimitResponse
}

struct PopoverAccountSectionData {
    let title: String
    let email: String?
    let plan: String?
    let systemIcon: String
}

struct PopoverStatusSectionData {
    let title: String
    let error: APIError?
}

enum PopoverDisplayPayload {
    case usage(PopoverUsageSectionData)
    case credits(PopoverCreditsSectionData)
    case overage(PopoverOverageSectionData)
    case account(PopoverAccountSectionData)
    case status(PopoverStatusSectionData)
}

struct PopoverDisplaySection: Identifiable {
    let id: String
    let kind: PopoverDisplaySectionKind
    let importance: PopoverSectionImportance
    let payload: PopoverDisplayPayload
}

struct PopoverLayoutSpec: Equatable {
    let density: PopoverDensity
    let phase: PopoverContentPhase
    let size: CGSize
    let bodyContentHeight: CGFloat
    let bodyInsets: EdgeInsets
    let contentBottomSpacing: CGFloat
    let sectionSpacing: CGFloat

    var isCompact: Bool {
        density.isCompact
    }
}
