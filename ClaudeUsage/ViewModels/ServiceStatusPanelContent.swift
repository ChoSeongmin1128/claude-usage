import Foundation

/// 메뉴바 서비스 상태 패널의 내용. 서비스 순서, 문구, 줄 구성은 여기서 정하고 화면은 그대로 그린다.
struct ServiceStatusPanelContent: Equatable {
    static let caption = "서비스 상태"
    static let serviceOrder: [AppProviderKind] = [.claude, .codex]
    /// 장애가 몰려도 패널이 화면을 덮지 않도록 서비스마다 세 줄까지만 보이고 나머지는 개수로 줄인다.
    /// 앱이 쓰는 제품의 장애가 앞에 오므로 줄어드는 쪽은 관계가 먼 장애다.
    static let rowLimit = 3

    enum Tone: Equatable {
        case normal
        case minor
        case major
    }

    struct Row: Equatable {
        let title: String
        let components: String?
        let updatedText: String?

        init(title: String, components: String? = nil, updatedText: String? = nil) {
            self.title = title
            self.components = components
            self.updatedText = updatedText
        }

        var detail: String? {
            let parts = [components, updatedText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    struct Service: Equatable {
        let kind: AppProviderKind
        let name: String
        let tone: Tone
        let stateText: String
        let rows: [Row]
        let overflowText: String?
    }

    let services: [Service]

    /// 한 번도 읽지 못한 서비스는 빠진다. 보여 줄 서비스가 없으면 패널을 띄우지 않는다.
    static func make(
        statuses: [AppProviderKind: ProviderSystemStatus],
        now: Date = Date()
    ) -> ServiceStatusPanelContent? {
        let services = serviceOrder.compactMap { kind in
            statuses[kind].map { service(kind: kind, status: $0, now: now) }
        }
        return services.isEmpty ? nil : ServiceStatusPanelContent(services: services)
    }

    /// 패널은 화면에만 보이므로 같은 내용을 메뉴바 버튼의 접근성 도움말로 제공한다. 계속 바뀌는 상대 시각은 뺀다.
    var accessibilitySummary: String {
        let blocks = services.map { service in
            var parts = [service.name + " " + service.stateText] + service.rows.map(\.title)
            if let overflow = service.overflowText {
                parts.append(overflow)
            }
            return parts.joined(separator: ", ")
        }
        return Self.caption + ": " + blocks.joined(separator: ". ")
    }

    private static func service(kind: AppProviderKind, status: ProviderSystemStatus, now: Date) -> Service {
        let indicator = status.effectiveIndicator
        let rows: [Row]
        let hiddenCount: Int
        let overflowUnit: String
        if !status.activeIncidents.isEmpty {
            rows = status.activeIncidents.prefix(rowLimit).map { incident in
                Row(
                    title: incident.name,
                    components: incident.affectedComponents.isEmpty
                        ? nil : incident.affectedComponents.joined(separator: ", "),
                    updatedText: incident.latestUpdateAt
                        .flatMap(TimeFormatter.validatedResetDate)
                        .map { TimeFormatter.elapsed(since: $0, now: now) + " 업데이트" }
                )
            }
            hiddenCount = status.activeIncidents.count - rows.count
            overflowUnit = "건"
        } else {
            rows = status.componentIssues.prefix(rowLimit).map { issue in
                Row(title: issue.name + " " + issue.indicator.displayText)
            }
            hiddenCount = status.componentIssues.count - rows.count
            overflowUnit = "개"
        }
        return Service(
            kind: kind,
            name: kind.displayName,
            tone: tone(for: indicator),
            stateText: indicator == .none ? "정상" : indicator.displayText,
            rows: rows,
            overflowText: hiddenCount > 0 ? "+\(hiddenCount)\(overflowUnit)" : nil
        )
    }

    private static func tone(for indicator: StatusIndicator) -> Tone {
        switch indicator {
        case .none: return .normal
        case .minor: return .minor
        case .major, .critical: return .major
        }
    }
}
