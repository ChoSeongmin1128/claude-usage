// Pure mapping from verified quota snapshots to surface presentations.
import Foundation

nonisolated enum AntigravityQuotaPresentationMapper {
    static func map(
        snapshot: AntigravityQuotaSnapshot,
        settings: AntigravityDisplaySettings,
        context requestedContext:
            AntigravityQuotaPresentationContext? = nil,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "ko_KR"),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AntigravityQuotaPresentation {
        let context = AntigravityQuotaPresentationContext(
            phase: requestedContext?.phase ?? .current,
            decodeIssueCount: max(
                requestedContext?.decodeIssueCount ?? 0,
                snapshot.decodeIssues.count
            )
        )
        let allGroups = makeGroups(
            from: snapshot.lanes,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        let orderedLanes = allGroups.flatMap(\.lanes)
        let standardLanes = displayedLanes(
            intent: settings.standard,
            from: orderedLanes
        )
        let compactLanes = displayedLanes(
            intent: settings.compact,
            from: orderedLanes
        )
        let groups = regroup(
            standardLanes,
            using: allGroups
        )
        let identityRail = makeIdentityRail(
            snapshot: snapshot,
            context: context,
            now: now
        )

        let menuBarSelection = selection(
            policy: settings.menuBar.laneSelection,
            surface: .menuBar,
            from: orderedLanes
        )
        let additionalMenuBarLanes =
            settings.menuBar.effectiveAdditionalLaneIDs
                .compactMap { laneID in
                    orderedLanes.first {
                        $0.id == laneID
                            && $0.value.usedPercentage != nil
                    }
                }
                .filter {
                    $0.id != menuBarSelection.lane?.id
                }

        let compact = compactPresentation(
            selectedLanes: compactLanes
        )
        let menuBar = menuBarPresentation(
            selectedLanes:
                [menuBarSelection.lane]
                    .compactMap { $0 }
                    + additionalMenuBarLanes,
            groups: groups,
            identityRail: identityRail,
            settings: settings,
            now: now,
            locale: locale,
            timeZone: timeZone
        )

        return AntigravityQuotaPresentation(
            context: context,
            allGroups: allGroups,
            groups: groups,
            compact: compact,
            menuBar: menuBar,
            identityRail: identityRail,
            notices: [menuBarSelection.notice]
                .compactMap { $0 }
        )
    }

    static func map(
        state: AntigravityPresentationState,
        settings: AntigravityDisplaySettings,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "ko_KR"),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AntigravityQuotaPresentationMappingResult {
        let snapshot: AntigravityQuotaSnapshot
        let context: AntigravityQuotaPresentationContext

        switch state {
        case .ready(let readySnapshot):
            snapshot = readySnapshot
            context = AntigravityQuotaPresentationContext(
                decodeIssueCount: readySnapshot.decodeIssues.count
            )
        case let .partial(partialSnapshot, issues):
            snapshot = partialSnapshot
            context = AntigravityQuotaPresentationContext(
                decodeIssueCount: max(
                    1,
                    max(
                        partialSnapshot.decodeIssues.count,
                        issues.count
                    )
                )
            )
        case .refreshing(previous: let previous?):
            snapshot = previous
            context = AntigravityQuotaPresentationContext(
                phase: .refreshing,
                decodeIssueCount: previous.decodeIssues.count
            )
        case let .stale(staleSnapshot, failure):
            snapshot = staleSnapshot
            context = AntigravityQuotaPresentationContext(
                phase: .stale(failure),
                decodeIssueCount: staleSnapshot.decodeIssues.count
            )
        case .disabled,
             .setupRequired,
             .refreshing(previous: nil),
             .accountMismatch,
             .limited,
             .identityOnly,
             .failed:
            return .unavailable(state)
        }

        return .content(
            map(
                snapshot: snapshot,
                settings: settings,
                context: context,
                now: now,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    private static func makeGroups(
        from lanes: [AntigravityQuotaLane],
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> [AntigravityQuotaGroupPresentation] {
        let grouped = Dictionary(grouping: lanes, by: \.scope)
        return grouped.keys.sorted(by: scopePrecedes).map { scope in
            let orderedLanes = (grouped[scope] ?? [])
                .sorted(by: lanePrecedes)
                .map {
                    lanePresentation(
                        from: $0,
                        now: now,
                        locale: locale,
                        timeZone: timeZone
                    )
                }
            return AntigravityQuotaGroupPresentation(
                id: groupID(for: scope),
                title: scopeTitle(for: scope),
                isUnknownScope: isUnknown(scope),
                lanes: orderedLanes
            )
        }
    }

    private static func lanePresentation(
        from lane: AntigravityQuotaLane,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> AntigravityQuotaLanePresentation {
        let scopeTitle = scopeTitle(for: lane.scope)
        let cadenceTitle = cadenceTitle(for: lane.cadence)
        let resetText = resetText(
            for: lane,
            now: now,
            locale: locale,
            timeZone: timeZone
        )
        let value = valuePresentation(for: lane)
        let tone = riskTone(for: value)
        let percentageText = value.usedPercentage.map(formatPercentage)
        let valueSummary = summaryText(for: value)
        let tooltip = [
            "\(scopeTitle) · \(cadenceTitle)",
            valueSummary,
            resetText,
        ].joined(separator: "\n")
        let accessibilityValue = accessibilityValue(
            for: value,
            resetText: resetText
        )

        return AntigravityQuotaLanePresentation(
            id: lane.id,
            scopeTitle: scopeTitle,
            cadenceTitle: cadenceTitle,
            compactLabel: "\(compactScopeTitle(for: lane.scope)) · \(cadenceTitle)",
            menuLabel: "\(menuScopeTitle(for: lane.scope))·\(menuCadenceTitle(for: lane.cadence))",
            cadence: lane.cadence,
            value: value,
            percentageText: percentageText,
            resetAt: lane.resetAt,
            resetText: resetText,
            tone: tone,
            isUnknownScope: isUnknown(lane.scope),
            isUnknownCadence: isUnknown(lane.cadence),
            tooltip: tooltip,
            accessibilityLabel: "\(scopeTitle), \(cadenceTitle) 한도",
            accessibilityValue: accessibilityValue
        )
    }

    private static func valuePresentation(
        for lane: AntigravityQuotaLane
    ) -> AntigravityQuotaValuePresentation {
        switch lane.availability {
        case .disabled:
            return .unavailable(.disabled)
        case .unknown:
            return .unavailable(.notReported)
        case .available:
            guard let remainingFraction = lane.remainingFraction,
                  remainingFraction.isFinite,
                  (0 ... 1).contains(remainingFraction)
            else {
                return .unavailable(.notReported)
            }
            return .available(
                usedPercentage: (1 - remainingFraction) * 100,
                remainingPercentage: remainingFraction * 100
            )
        }
    }

    private static func riskTone(
        for value: AntigravityQuotaValuePresentation
    ) -> AntigravityQuotaRiskTone {
        guard let usedPercentage = value.usedPercentage else {
            return .neutral
        }
        if usedPercentage >= 90 {
            return .critical
        }
        if usedPercentage >= 75 {
            return .warning
        }
        if usedPercentage >= 50 {
            return .attention
        }
        return .healthy
    }

    private static func selection(
        policy: AntigravityDisplaySettings.SingleLaneSelectionPolicy,
        surface: AntigravityQuotaPresentationSurface,
        from lanes: [AntigravityQuotaLanePresentation]
    ) -> (
        lane: AntigravityQuotaLanePresentation?,
        notice: AntigravityQuotaPresentationNotice?
    ) {
        switch policy {
        case .automaticMostConstrained:
            return (mostConstrainedLane(in: lanes), nil)
        case .fixed(let requestedLaneID):
            if let fixedLane = lanes.first(where: {
                $0.id == requestedLaneID && $0.value.usedPercentage != nil
            }) {
                return (fixedLane, nil)
            }

            let fallback = mostConstrainedLane(in: lanes)
            let message: String
            if let fallback {
                message = [
                    "고정한 한도를 현재 응답에서 확인할 수 없어",
                    "\(fallback.scopeTitle) \(fallback.cadenceTitle)을 대신 표시합니다.",
                ].joined(separator: " ")
            } else {
                message = [
                    "고정한 한도를 현재 응답에서 확인할 수 없고,",
                    "자동으로 선택할 수 있는 다른 한도도 없습니다.",
                ].joined(separator: " ")
            }
            return (
                fallback,
                AntigravityQuotaPresentationNotice(
                    surface: surface,
                    kind: .fixedLaneUnavailable(
                        requestedLaneID: requestedLaneID,
                        fallbackLaneID: fallback?.id
                    ),
                    title: "표시 한도를 자동으로 선택했습니다",
                    message: message
                )
            )
        }
    }

    private static func mostConstrainedLane(
        in lanes: [AntigravityQuotaLanePresentation]
    ) -> AntigravityQuotaLanePresentation? {
        var selected: AntigravityQuotaLanePresentation?
        for lane in lanes {
            guard let candidatePercentage = lane.value.usedPercentage else {
                continue
            }
            guard let currentPercentage = selected?.value.usedPercentage else {
                selected = lane
                continue
            }
            if candidatePercentage > currentPercentage {
                selected = lane
            }
        }
        return selected
    }

    private static func displayedLanes(
        intent:
            AntigravityDisplaySettings.LaneListPresentationIntent,
        from lanes: [AntigravityQuotaLanePresentation]
    ) -> [AntigravityQuotaLanePresentation] {
        var laneByID: [
            AntigravityQuotaLaneID:
                AntigravityQuotaLanePresentation
        ] = [:]
        for lane in lanes
        where laneByID[lane.id] == nil {
            laneByID[lane.id] = lane
        }
        var orderedIDs = intent.orderedLaneIDs
        let persistedIDs = Set(orderedIDs)
        orderedIDs.append(
            contentsOf: lanes.map(\.id).filter {
                !persistedIDs.contains($0)
            }
        )

        let visible = orderedIDs.compactMap {
            intent.hiddenLaneIDs.contains($0)
                ? nil
                : laneByID[$0]
        }
        guard intent.orderingPolicy == .mostConstrainedFirst else {
            return visible
        }

        var stableOrder:
            [AntigravityQuotaLaneID: Int] = [:]
        for (index, lane) in visible.enumerated()
        where stableOrder[lane.id] == nil {
            stableOrder[lane.id] = index
        }
        return visible.sorted { lhs, rhs in
            switch (
                lhs.value.usedPercentage,
                rhs.value.usedPercentage
            ) {
            case let (lhsValue?, rhsValue?):
                if lhsValue != rhsValue {
                    return lhsValue > rhsValue
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return (stableOrder[lhs.id] ?? .max)
                < (stableOrder[rhs.id] ?? .max)
        }
    }

    private static func regroup(
        _ lanes: [AntigravityQuotaLanePresentation],
        using allGroups: [AntigravityQuotaGroupPresentation]
    ) -> [AntigravityQuotaGroupPresentation] {
        let templateByLaneID: [
            AntigravityQuotaLaneID:
                AntigravityQuotaGroupPresentation
        ] = {
            var value: [
                AntigravityQuotaLaneID:
                    AntigravityQuotaGroupPresentation
            ] = [:]
            for group in allGroups {
                for lane in group.lanes
                where value[lane.id] == nil {
                    value[lane.id] = group
                }
            }
            return value
        }()

        var result: [AntigravityQuotaGroupPresentation] = []
        var groupIndex: [
            AntigravityQuotaGroupPresentationID: Int
        ] = [:]
        for lane in lanes {
            guard let template = templateByLaneID[lane.id] else {
                continue
            }
            if let index = groupIndex[template.id] {
                let current = result[index]
                result[index] = AntigravityQuotaGroupPresentation(
                    id: current.id,
                    title: current.title,
                    isUnknownScope: current.isUnknownScope,
                    lanes: current.lanes + [lane]
                )
            } else {
                groupIndex[template.id] = result.count
                result.append(
                    AntigravityQuotaGroupPresentation(
                        id: template.id,
                        title: template.title,
                        isUnknownScope: template.isUnknownScope,
                        lanes: [lane]
                    )
                )
            }
        }
        return result
    }

    private static func compactPresentation(
        selectedLanes: [AntigravityQuotaLanePresentation]
    ) -> AntigravityCompactQuotaPresentation {
        let metrics:
            [AntigravityCompactQuotaMetricPresentation] =
            selectedLanes.compactMap { lane
                -> AntigravityCompactQuotaMetricPresentation?
                in
            guard let usedPercentage = lane.value.usedPercentage,
                  let percentageText = lane.percentageText
            else {
                return nil
            }
            return AntigravityCompactQuotaMetricPresentation(
                laneID: lane.id,
                label: lane.compactLabel,
                usedPercentage: usedPercentage,
                percentageText: percentageText,
                tone: lane.tone,
                tooltip: lane.tooltip,
                accessibilityLabel: lane.accessibilityLabel,
                accessibilityValue: lane.accessibilityValue
            )
        }
        guard !metrics.isEmpty else {
            return .unavailable
        }
        return AntigravityCompactQuotaPresentation(
            metrics: metrics,
            unavailableText: nil
        )
    }

    private static func menuBarPresentation(
        selectedLanes: [AntigravityQuotaLanePresentation],
        groups: [AntigravityQuotaGroupPresentation],
        identityRail: ProviderIdentityRailProjection,
        settings: AntigravityDisplaySettings,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> AntigravityMenuBarQuotaPresentation {
        let tooltip = menuBarTooltip(
            groups: groups,
            identityRail: identityRail
        )
        guard let selectedLane = selectedLanes.first,
              selectedLane.percentageText != nil
        else {
            return AntigravityMenuBarQuotaPresentation(
                isVisible: settings.menuBar.isVisible,
                showsProviderIcon: settings.menuBar.showsProviderIcon,
                style: settings.menuBar.style,
                selectedLaneID: nil,
                regularText: nil,
                condensedText: nil,
                gaugePercentage: nil,
                showsGaugePercentage:
                    settings.menuBar.showsGaugePercentage,
                tooltip: tooltip,
                tone: .neutral,
                accessibilityLabel: "Antigravity 메뉴 막대 사용량",
                accessibilityValue: [
                    "확인 가능한 사용량 한도 없음",
                    identityRail.accessibilityValue,
                ].joined(separator: ", ")
            )
        }

        let regularText = selectedLanes.compactMap { lane -> String? in
            guard let percentageText = lane.percentageText else {
                return nil
            }
            var components = [lane.menuLabel]
            if settings.menuBar.showsSelectedLanePercentage {
                components.append(percentageText)
            }
            if settings.menuBar.showsSelectedLaneResetTime {
                components.append(
                    menuBarResetText(
                        lane,
                        timeFormat: settings.menuBar.timeFormat,
                        now: now,
                        locale: locale,
                        timeZone: timeZone
                    )
                )
            }
            return components.joined(separator: " ")
        }
        let condensedText = selectedLanes.compactMap {
            lane -> String? in
            if settings.menuBar.showsSelectedLanePercentage {
                return lane.percentageText
            }
            if settings.menuBar.showsSelectedLaneResetTime {
                return menuBarResetText(
                    lane,
                    timeFormat: settings.menuBar.timeFormat,
                    now: now,
                    locale: locale,
                    timeZone: timeZone
                )
            }
            return nil
        }

        return AntigravityMenuBarQuotaPresentation(
            isVisible: settings.menuBar.isVisible,
            showsProviderIcon: settings.menuBar.showsProviderIcon,
            style: settings.menuBar.style,
            selectedLaneID: selectedLane.id,
            regularText: regularText.joined(separator: " · "),
            condensedText:
                condensedText.isEmpty
                    ? nil
                    : condensedText.joined(separator: " · "),
            gaugePercentage: menuBarGaugePercentage(
                selectedLane,
                settings: settings.menuBar
            ),
            showsGaugePercentage:
                settings.menuBar.showsGaugePercentage,
            tooltip: tooltip,
            tone: selectedLane.tone,
            accessibilityLabel: "Antigravity 메뉴 막대 사용량",
            accessibilityValue: [
                selectedLanes.map {
                    "\($0.accessibilityLabel), \($0.accessibilityValue)"
                }.joined(separator: "; "),
                identityRail.accessibilityValue,
            ].joined(separator: ", ")
        )
    }

    private static func menuBarGaugePercentage(
        _ lane: AntigravityQuotaLanePresentation,
        settings:
            AntigravityDisplaySettings.MenuBarPresentationIntent
    ) -> Double? {
        switch settings.style {
        case .none:
            return nil
        case .batteryBar:
            return lane.value.usedPercentage
        case .circular:
            switch settings.circularValue {
            case .usage:
                return lane.value.usedPercentage
            case .remaining:
                return lane.value.remainingPercentage
            }
        }
    }

    private static func makeIdentityRail(
        snapshot: AntigravityQuotaSnapshot,
        context: AntigravityQuotaPresentationContext,
        now: Date
    ) -> ProviderIdentityRailProjection {
        let identity = snapshot.identity
            ?? snapshot.provenance.accountIdentity
        let accountLabel = maskedAccountLabel(identity)
        let sourceLabel = sourceLabel(snapshot.provenance.transport)
        let freshnessLabel = relativeFreshness(
            fetchedAt: snapshot.fetchedAt,
            now: now
        )
        var statusLabels: [String] = []
        var statusDetails: [String] = []
        var tone = ProviderIdentityRailTone.standard

        if context.decodeIssueCount > 0 {
            statusLabels.append("일부 한도를 읽지 못함")
            statusDetails.append(
                "응답 항목 \(context.decodeIssueCount)건을 완전히 해석하지 못했습니다. 확인된 한도는 계속 표시합니다."
            )
            tone = .attention
        }

        switch context.phase {
        case .current:
            break
        case .refreshing:
            statusLabels.append("갱신 중")
            statusDetails.append(
                "마지막으로 확인한 한도를 유지하며 새 한도를 확인 중입니다."
            )
        case .stale:
            statusLabels.append("이전 데이터")
            statusDetails.append(
                "최근 갱신에 실패해 마지막으로 확인한 한도를 표시합니다."
            )
            tone = .attention
        }

        let accessibilityParts = [
            "조회 계정 \(accountLabel)",
            "조회 경로 \(sourceLabel)",
            freshnessLabel,
        ] + statusDetails
        let accessibilityValue = accessibilityParts.joined(
            separator: ", "
        )
        let tooltip = ([
            "Antigravity 조회 정보",
            "조회 계정: \(accountLabel)",
            "조회 경로: \(sourceLabel)",
            freshnessLabel,
        ] + statusDetails).joined(separator: "\n")

        return ProviderIdentityRailProjection(
            providerName: "Antigravity",
            accountLabel: accountLabel,
            sourceLabel: sourceLabel,
            freshnessLabel: freshnessLabel,
            statusLabels: statusLabels,
            tone: tone,
            tooltip: tooltip,
            accessibilityLabel: "Antigravity 조회 정보",
            accessibilityValue: accessibilityValue
        )
    }

    private static func menuBarTooltip(
        groups: [AntigravityQuotaGroupPresentation],
        identityRail: ProviderIdentityRailProjection
    ) -> String {
        var lines = [
            identityRail.providerName,
            "계정: \(identityRail.accountLabel)",
            "조회: \(identityRail.sourceLabel)",
            "갱신: \(identityRail.freshnessLabel)",
        ]
        lines.append(contentsOf: identityRail.statusLabels.map {
            "상태: \($0)"
        })

        if groups.isEmpty {
            lines.append("")
            lines.append("확인 가능한 사용량 한도가 없습니다.")
            return lines.joined(separator: "\n")
        }

        for group in groups {
            lines.append("")
            lines.append(group.title)
            for lane in group.lanes {
                lines.append(
                    "  \(lane.cadenceTitle): \(summaryText(for: lane.value)) · \(lane.resetText)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func summaryText(
        for value: AntigravityQuotaValuePresentation
    ) -> String {
        switch value {
        case let .available(usedPercentage, remainingPercentage):
            return "\(formatPercentage(usedPercentage)) 사용 · \(formatPercentage(remainingPercentage)) 남음"
        case .unavailable(let reason):
            return reason.displayText
        }
    }

    private static func accessibilityValue(
        for value: AntigravityQuotaValuePresentation,
        resetText: String
    ) -> String {
        switch value {
        case let .available(usedPercentage, remainingPercentage):
            return [
                "\(formatSpokenPercentage(usedPercentage)) 사용",
                "\(formatSpokenPercentage(remainingPercentage)) 남음",
                resetText,
            ].joined(separator: ", ")
        case .unavailable(let reason):
            return [reason.displayText, resetText].joined(separator: ", ")
        }
    }

    private static func resetText(
        for lane: AntigravityQuotaLane,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        guard let resetAt = lane.resetAt else {
            return "갱신 시각 알 수 없음"
        }
        return TimeFormatter.formatUsageResetDetail(
            resetAt: resetAt,
            isWeekly: lane.cadence != .fiveHour,
            now: now,
            locale: locale,
            timeZone: timeZone,
            label: nil
        )
    }

    private static func menuBarResetText(
        _ lane: AntigravityQuotaLanePresentation,
        timeFormat:
            AntigravityDisplaySettings.MenuBarPresentationIntent.TimeFormat,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        guard let resetAt = lane.resetAt else {
            return "갱신 시각 알 수 없음"
        }
        switch timeFormat {
        case .remaining:
            return relativeResetText(resetAt: resetAt, now: now)
        case .h24:
            return formattedMenuBarResetDate(
                resetAt,
                cadence: lane.cadence,
                usesTwelveHourClock: false,
                locale: locale,
                timeZone: timeZone
            )
        case .h12:
            return formattedMenuBarResetDate(
                resetAt,
                cadence: lane.cadence,
                usesTwelveHourClock: true,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    private static func relativeResetText(
        resetAt: Date,
        now: Date
    ) -> String {
        let interval = resetAt.timeIntervalSince(now)
        guard interval > 0 else {
            return "갱신 시각 확인 필요"
        }
        let totalMinutes = max(1, Int(interval / 60))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60
        if days > 0, hours > 0 {
            return "\(days)일 \(hours)시간 후"
        }
        if days > 0 {
            return "\(days)일 후"
        }
        if hours > 0, minutes > 0 {
            return "\(hours)시간 \(minutes)분 후"
        }
        if hours > 0 {
            return "\(hours)시간 후"
        }
        return "\(minutes)분 후"
    }

    private static func formattedMenuBarResetDate(
        _ date: Date,
        cadence: AntigravityQuotaCadence,
        usesTwelveHourClock: Bool,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let clockFormat = usesTwelveHourClock ? "a h:mm" : "HH:mm"
        switch cadence {
        case .weekly:
            formatter.dateFormat = "EEE \(clockFormat)"
        case .fiveHour, .unknown:
            formatter.dateFormat = clockFormat
        }
        return formatter.string(from: date)
    }

    private static func formattedResetDate(
        _ date: Date,
        cadence: AntigravityQuotaCadence,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch cadence {
        case .weekly:
            formatter.dateFormat = "EEEE HH:mm"
        case .fiveHour, .unknown:
            formatter.dateFormat = "M월 d일 HH:mm"
        }
        return formatter.string(from: date)
    }

    private static func relativeFreshness(
        fetchedAt: Date,
        now: Date
    ) -> String {
        let interval = max(0, now.timeIntervalSince(fetchedAt))
        if interval < 60 {
            return "방금 갱신"
        }
        if interval < 3_600 {
            return "\(max(1, Int(interval / 60)))분 전 갱신"
        }
        if interval < 86_400 {
            return "\(max(1, Int(interval / 3_600)))시간 전 갱신"
        }
        return "\(max(1, Int(interval / 86_400)))일 전 갱신"
    }

    private static func maskedAccountLabel(
        _ identity: ProviderAccountIdentity?
    ) -> String {
        guard let identity else {
            return "계정 미확인"
        }
        if let email = nonEmpty(identity.email) {
            let localPart = email.split(
                separator: "@",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? email
            let visibleLocalPart: String
            if localPart.count > 12 {
                visibleLocalPart = String(localPart.prefix(10)) + "…"
            } else {
                visibleLocalPart = localPart
            }
            return visibleLocalPart + "@…"
        }
        if nonEmpty(identity.stableAccountID) != nil {
            return "계정 확인됨"
        }
        return "계정 미확인"
    }

    private static func sourceLabel(
        _ transport: AntigravityQuotaProvenance.Transport
    ) -> String {
        switch transport {
        case .localAppRPC:
            "Antigravity 앱"
        case .borrowedAGYRPC, .managedAGYRPC:
            "AGY CLI"
        case .googleOAuth:
            "Google 계정"
        }
    }

    private static func scopePrecedes(
        _ lhs: AntigravityQuotaScope,
        _ rhs: AntigravityQuotaScope
    ) -> Bool {
        let lhsKey = scopeSortKey(lhs)
        let rhsKey = scopeSortKey(rhs)
        if lhsKey.rank != rhsKey.rank {
            return lhsKey.rank < rhsKey.rank
        }
        if lhsKey.detail != rhsKey.detail {
            return lhsKey.detail.localizedStandardCompare(rhsKey.detail)
                == .orderedAscending
        }
        if lhsKey.upstreamID != rhsKey.upstreamID {
            return lhsKey.upstreamID.localizedStandardCompare(
                rhsKey.upstreamID
            ) == .orderedAscending
        }
        return lhsKey.label.localizedStandardCompare(rhsKey.label)
            == .orderedAscending
    }

    private static func lanePrecedes(
        _ lhs: AntigravityQuotaLane,
        _ rhs: AntigravityQuotaLane
    ) -> Bool {
        let lhsKey = cadenceSortKey(lhs.cadence)
        let rhsKey = cadenceSortKey(rhs.cadence)
        if lhsKey.rank != rhsKey.rank {
            return lhsKey.rank < rhsKey.rank
        }
        if lhsKey.detail != rhsKey.detail {
            return lhsKey.detail.localizedStandardCompare(rhsKey.detail)
                == .orderedAscending
        }
        return lhs.id.rawValue.localizedStandardCompare(rhs.id.rawValue)
            == .orderedAscending
    }

    private static func scopeSortKey(
        _ scope: AntigravityQuotaScope
    ) -> (
        rank: Int,
        detail: String,
        upstreamID: String,
        label: String
    ) {
        switch scope {
        case .gemini:
            (0, "", "gemini", "")
        case .thirdPartyModels:
            (1, "", "third-party-models", "")
        case let .unknown(id, label):
            (2, nonEmpty(label) ?? id, id, label ?? "")
        }
    }

    private static func cadenceSortKey(
        _ cadence: AntigravityQuotaCadence
    ) -> (rank: Int, detail: String) {
        switch cadence {
        case .fiveHour:
            (0, "")
        case .weekly:
            (1, "")
        case .unknown(let rawValue):
            (2, rawValue)
        }
    }

    private static func scopeTitle(
        for scope: AntigravityQuotaScope
    ) -> String {
        switch scope {
        case .gemini:
            "Gemini"
        case .thirdPartyModels:
            "Claude · GPT"
        case let .unknown(id, label):
            nonEmpty(label) ?? nonEmpty(id) ?? "기타 한도"
        }
    }

    private static func compactScopeTitle(
        for scope: AntigravityQuotaScope
    ) -> String {
        switch scope {
        case .gemini:
            "Gemini"
        case .thirdPartyModels:
            "Claude·GPT"
        case .unknown:
            scopeTitle(for: scope)
        }
    }

    private static func menuScopeTitle(
        for scope: AntigravityQuotaScope
    ) -> String {
        switch scope {
        case .gemini:
            "G"
        case .thirdPartyModels:
            "C/G"
        case .unknown:
            scopeTitle(for: scope)
        }
    }

    private static func cadenceTitle(
        for cadence: AntigravityQuotaCadence
    ) -> String {
        switch cadence {
        case .fiveHour:
            "5시간"
        case .weekly:
            "주간"
        case .unknown(let rawValue):
            nonEmpty(rawValue) ?? "기타 주기"
        }
    }

    private static func menuCadenceTitle(
        for cadence: AntigravityQuotaCadence
    ) -> String {
        switch cadence {
        case .fiveHour:
            "5h"
        case .weekly:
            "주"
        case .unknown:
            cadenceTitle(for: cadence)
        }
    }

    private static func groupID(
        for scope: AntigravityQuotaScope
    ) -> AntigravityQuotaGroupPresentationID {
        switch scope {
        case .gemini:
            .gemini
        case .thirdPartyModels:
            .thirdPartyModels
        case let .unknown(id, label):
            .unknown(upstreamID: id, label: label)
        }
    }

    private static func isUnknown(
        _ scope: AntigravityQuotaScope
    ) -> Bool {
        if case .unknown = scope {
            return true
        }
        return false
    }

    private static func isUnknown(
        _ cadence: AntigravityQuotaCadence
    ) -> Bool {
        if case .unknown = cadence {
            return true
        }
        return false
    }

    private static func formatPercentage(
        _ percentage: Double
    ) -> String {
        let roundedToTenth = (percentage * 10).rounded() / 10
        if roundedToTenth == roundedToTenth.rounded() {
            return String(format: "%.0f%%", roundedToTenth)
        }
        return String(format: "%.1f%%", roundedToTenth)
    }

    private static func formatSpokenPercentage(
        _ percentage: Double
    ) -> String {
        formatPercentage(percentage)
            .replacingOccurrences(of: "%", with: "퍼센트")
    }

    private static func nonEmpty(
        _ value: String?
    ) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
