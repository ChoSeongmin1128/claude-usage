import Foundation

/// 메뉴바 서비스 상태 패널의 내용. 서비스 순서, 문구, 줄 구성은 여기서 정하고 화면은 그대로 그린다.
struct ServiceStatusPanelContent: Equatable {
    static let caption = "서비스 상태"
    static let serviceOrder: [AppProviderKind] = [.claude, .codex]
    enum Tone: Equatable {
        case normal
        case minor
        case major
    }

    struct Row: Equatable, Identifiable {
        var id: String { incidentIdentity ?? title }
        var incidentIdentity: String? = nil
        let title: String
        let components: String?
        let updatedText: String?
        var phase: String? = nil

        init(title: String, components: String? = nil, updatedText: String? = nil, phase: String? = nil) {
            self.title = title
            self.components = components
            self.updatedText = updatedText
            self.phase = phase
        }

        var detail: String? {
            let parts = [components, phase, updatedText].compactMap { $0 }
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
    var usage = MenuBarHoverUsageContent(providers: [])

    /// 한 번도 읽지 못한 서비스는 빠진다. 보여 줄 서비스가 없으면 패널을 띄우지 않는다.
    static func make(
        statuses: [AppProviderKind: ProviderSystemStatus],
        now: Date = Date(),
        usage: MenuBarHoverUsageContent = MenuBarHoverUsageContent(providers: [])
    ) -> ServiceStatusPanelContent? {
        let services = serviceOrder.compactMap { kind in
            statuses[kind].map { service(kind: kind, status: $0, now: now) }
        }
        let scopedUsage = MenuBarHoverUsageContent(
            providers: usage.providers.map { provider in
                var value = provider
                value.serviceTone = services.first { $0.kind == provider.kind }?.tone ?? provider.serviceTone
                return value
            })
        return services.isEmpty && usage.providers.isEmpty
            ? nil : ServiceStatusPanelContent(services: services, usage: scopedUsage)
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
        let statusSummary = services.isEmpty ? nil : Self.caption + ": " + blocks.joined(separator: ". ")
        let usageBlocks = usage.providers.map { provider in
            let rows = provider.items.map { item in
                let meaning = item.value.hasSuffix("%") ? " " + provider.basis.label : ""
                return item.title + " " + item.value + meaning + (item.detail.map { ", " + $0 } ?? "")
            }
            return ([provider.kind.displayName] + rows + [provider.stateText].compactMap { $0 }).joined(separator: ", ")
        }
        let usageSummary = usageBlocks.isEmpty ? nil : "사용량: " + usageBlocks.joined(separator: ". ")
        return [usageSummary, statusSummary].compactMap { $0 }.joined(separator: ". ")
    }

    private static func service(kind: AppProviderKind, status: ProviderSystemStatus, now: Date) -> Service {
        let indicator = status.effectiveIndicator
        let rows: [Row]
        if !status.activeIncidents.isEmpty {
            rows =
                status.activeIncidents.map { incident in
                    var row = Row(
                    title: incident.name,
                    components: incident.affectedComponents.isEmpty
                        ? nil : incident.affectedComponents.joined(separator: ", "),
                    updatedText: incident.latestUpdateAt
                        .flatMap(TimeFormatter.validatedResetDate)
                        .map { TimeFormatter.elapsed(since: $0, now: now) + " 업데이트" }
                )
                    row.phase = phaseText(incident.status)
                    row.incidentIdentity = incident.id ?? incident.shortlink
                    return row
                }
                + status.componentIssues.filter { issue in
                    !status.activeIncidents.contains { $0.affectedComponents.contains(issue.name) }
                }.map { issue in Row(title: issue.name + " " + issue.indicator.displayText) }

        } else {
            rows = status.componentIssues.map { issue in
                Row(title: issue.name + " " + issue.indicator.displayText)
            }

        }
        return Service(
            kind: kind,
            name: kind.displayName,
            tone: tone(for: indicator),
            stateText: indicator == .none ? "정상" : indicator.displayText,
            rows: rows,
            overflowText: nil
        )
    }

    private static func phaseText(_ status: String) -> String? {
        switch status {
        case "investigating": "조사 중"
        case "identified": "원인 확인"
        case "monitoring": "복구 확인 중"
        case "resolved": "해결됨"
        default: nil
        }
    }

    private static func tone(for indicator: StatusIndicator) -> Tone {
        switch indicator {
        case .none: return .normal
        case .minor: return .minor
        case .major, .critical: return .major
        }
    }
}
