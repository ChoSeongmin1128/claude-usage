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
    case resetCredits
    case overage
    case account
    case status
    case accountPicker
    case accountRow
    case accountSummary
}

/// 여러 계정 화면의 한 계정 줄. 숫자는 게이지에만, 줄에는 상태와 시간만 쓴다.
struct PopoverAccountRowData: Identifiable, Equatable {
    let id: String
    let service: PopoverService
    let name: String
    let badges: [AccountBadge]
    let status: UsageAccountState.Status
    let usage: UsageAccountUsage?
    let fetchedAt: Date?
    let isRuntime: Bool
    let basis: UsageValueBasis
}

struct PopoverAccountPickerData: Equatable {
    struct Chip: Identifiable, Equatable {
        let id: String
        let name: String
        let isSelected: Bool
    }

    let service: PopoverService
    let chips: [Chip]
}

struct PopoverAccountSummaryData: Equatable {
    let text: String
    let isWarning: Bool
}

/// 여러 계정을 켜고 계정이 2개 이상일 때 팝오버에 넘기는 계정 목록
struct MultiAccountPresentation: Equatable {
    let service: PopoverService
    let mode: UsageAccountPreferences.PopoverMode
    let rows: [PopoverAccountRowData]
    let selectedIDs: [String]

    /// 숨긴 한도도 요약에는 넣는다. 문제가 없으면 한 줄로 끝낸다.
    var summary: PopoverAccountSummaryData {
        let threshold = AdaptiveRefreshPolicy.lowRemainingPercent
        let low = rows.filter { ($0.usage?.lowestRemainingPercent).map { $0 <= threshold } == true }
        let expired = rows.filter { $0.status == .loginExpired }
        var parts: [String] = []
        if !low.isEmpty { parts.append("남은 한도 \(PercentageText.string(threshold)) 이하 \(low.count)개") }
        if !expired.isEmpty { parts.append("로그인 만료 \(expired.count)개") }
        return parts.isEmpty
            ? PopoverAccountSummaryData(text: "모든 계정 여유 있음", isWarning: false)
            : PopoverAccountSummaryData(text: parts.joined(separator: ", "), isWarning: true)
    }

    func sections(catalog: [PopoverDisplaySection]) -> [PopoverDisplaySection] {
        func row(_ data: PopoverAccountRowData) -> PopoverDisplaySection {
            PopoverDisplaySection(
                id: "account-\(data.id)", kind: .accountRow, importance: .primary, payload: .accountRow(data))
        }
        let others = rows.filter { !$0.isRuntime }
        switch mode {
        case .pick:
            let picker = PopoverDisplaySection(
                id: "account-picker", kind: .accountPicker, importance: .primary,
                payload: .accountPicker(
                    PopoverAccountPickerData(
                        service: service,
                        chips: rows.map { .init(id: $0.id, name: $0.name, isSelected: selectedIDs.contains($0.id)) })))
            let runtimeSelected = rows.contains { $0.isRuntime && selectedIDs.contains($0.id) }
            return [picker] + (runtimeSelected ? catalog : []) + others.filter { selectedIDs.contains($0.id) }.map(row)
        case .featuredList:
            return catalog + others.map(row)
        case .summaryRows:
            let summary = PopoverDisplaySection(
                id: "account-summary", kind: .accountSummary, importance: .primary,
                payload: .accountSummary(self.summary))
            return [summary] + rows.map(row)
        }
    }
}

struct PopoverUsageSectionData {
    let title: String
    let compactLabel: String
    let percentage: Double
    let resetAt: String?
    let isWeekly: Bool
    let timeFormatStyle: TimeFormatStyle
    var basis: UsageValueBasis = .used
}

struct PopoverCreditsSectionData {
    let credits: CodexCredits
    var rateCardURL: URL? = nil
}

struct PopoverResetCreditsSectionData {
    let summary: ResetCreditSummary
    let isNew: Bool
    var receipt: ResetCreditSeenReceipt? = nil
}

struct PopoverOverageSectionData {
    let overage: OverageSpendLimitResponse
    var updatedAt: Date? = nil
    var isStale = false
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

    /// Optional explicit state text for non-error statuses. When nil, the view
    /// falls back to the provider's generic empty/error copy.
    let statusText: String?
    let message: String?

    init(
        title: String,
        error: APIError?,
        statusText: String? = nil,
        message: String? = nil
    ) {
        self.title = title
        self.error = error
        self.statusText = statusText
        self.message = message
    }
}

enum PopoverDisplayPayload {
    case usage(PopoverUsageSectionData)
    case credits(PopoverCreditsSectionData)
    case resetCredits(PopoverResetCreditsSectionData)
    case overage(PopoverOverageSectionData)
    case account(PopoverAccountSectionData)
    case status(PopoverStatusSectionData)
    case accountPicker(PopoverAccountPickerData)
    case accountRow(PopoverAccountRowData)
    case accountSummary(PopoverAccountSummaryData)
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
    var designIntroductionHeight: CGFloat = 0

    var isCompact: Bool {
        density.isCompact
    }
}
