import Foundation

nonisolated struct WhatsNewPage: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case openSettings(SettingsProviderPanel)
        case toggleResetCreditsInMenuBar
    }

    let version: String
    let symbol: String
    let title: String
    var body: String
    var action: Action?
    var actionTitle: String?

    var id: String { "\(version)/\(title)" }
}

/// 새 기능이 있는 버전만 페이지를 둔다. 버그 수정만 있는 버전은 여기에 넣지 않는다.
nonisolated enum WhatsNewCatalog {
    static let maximumPages = 5

    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            version: "2.8.0", symbol: "sidebar.left", title: "설정을 다섯 갈래로 정리",
            body: "일반, 계정, 한도, 모양, 업데이트로 나눴습니다. 한도 표에서 한도마다 메뉴바, 팝오버, 알림을 한 줄로 고릅니다.",
            action: .openSettings(.limits), actionTitle: "한도 설정 열기"),
        WhatsNewPage(
            version: "2.8.0", symbol: "clock", title: "남은 시간 1:23 형식",
            body: "시간 형식을 모든 서비스가 함께 씁니다. 남은 시간을 1:23처럼 짧게 보거나 주간 한도를 3d 02:12로 볼 수 있습니다.",
            action: .openSettings(.common), actionTitle: "일반 설정 열기"),
        WhatsNewPage(
            version: "2.8.0", symbol: "arrow.triangle.2.circlepath", title: "상황에 맞춘 자동 확인",
            body: "팝오버를 막 열었거나 Claude Code, Codex를 쓰는 중이거나 한도가 10% 이하로 남으면 2분마다, 오래 쓰지 않으면 최대 30분 간격으로 확인합니다."),
        WhatsNewPage(
            version: "2.9.0", symbol: "arrow.counterclockwise.circle", title: "메뉴바에 초기화권 표시",
            body: "받은 한도 초기화권 개수를 수치 옆에 ↺1처럼 보여줍니다. 새로 받으면 파란색, 48시간 안에 만료되면 빨간색입니다.",
            action: .toggleResetCreditsInMenuBar, actionTitle: "메뉴바에 표시"),
        WhatsNewPage(
            version: "2.10.0", symbol: "globe", title: "쓰는 브라우저에서 로그인 가져오기",
            body:
                "Chrome 말고도 Brave, Edge, Whale, Vivaldi, Firefox, Safari, Claude 앱에 로그인돼 있으면 그대로 가져옵니다. 기본 브라우저를 먼저 찾습니다.",
            action: .openSettings(.accounts), actionTitle: "계정 설정 열기"),
    ]

    static func notesText(_ note: UpdateNotesQueue.Note) -> (version: String, title: String, text: String) {
        switch note {
        case .timeFormatUnified:
            return ("2.8.0", "남은 시간 1:23 형식", "서비스마다 달랐던 시간 형식은 Claude 설정 값으로 맞췄습니다.")
        }
    }

    /// 마지막으로 본 버전 이후 페이지를 오래된 버전부터 이어 붙인다.
    static func pagesToShow(
        after lastSeen: String, upTo current: String, notes: [UpdateNotesQueue.Note] = [],
        catalog: [WhatsNewPage] = pages
    ) -> [WhatsNewPage] {
        var result = catalog.filter {
            VersionOrder.isNewer($0.version, than: lastSeen) && !VersionOrder.isNewer($0.version, than: current)
        }
        .enumerated()
        .sorted { lhs, rhs in
            lhs.element.version == rhs.element.version
                ? lhs.offset < rhs.offset : VersionOrder.isNewer(rhs.element.version, than: lhs.element.version)
        }
        .map(\.element)
        for note in notes {
            let line = notesText(note)
            if let index = result.firstIndex(where: { $0.version == line.version && $0.title == line.title }) {
                result[index].body += " " + line.text
            }
        }
        guard result.count > maximumPages else { return result }
        let kept = Array(result.prefix(maximumPages - 1))
        let rest = result.dropFirst(maximumPages - 1)
        let others = WhatsNewPage(
            version: rest.last?.version ?? current, symbol: "list.bullet", title: "그 밖의 변경",
            body: rest.map { "\($0.title) (\($0.version))" }.joined(separator: "\n"))
        return kept + [others]
    }

    /// 설정의 업데이트에서 다시 볼 때는 페이지가 있는 가장 최근 버전을 보여준다.
    static func latestPages(upTo current: String, catalog: [WhatsNewPage] = pages) -> [WhatsNewPage] {
        let versions = catalog.map(\.version).filter { !VersionOrder.isNewer($0, than: current) }
        guard let latest = versions.max(by: { VersionOrder.isNewer($1, than: $0) }) else { return [] }
        return catalog.filter { $0.version == latest }
    }
}

nonisolated enum WhatsNewState {
    static let lastSeenKey = AppIdentifiers.defaultsKey("whatsNewLastSeenVersion")

    /// 새로 설치하면 처음 설정이 대신하므로 현재 버전을 본 것으로 기록한다.
    static func prepare(defaults: UserDefaults, isExistingInstall: Bool, currentVersion: String) {
        guard defaults.string(forKey: lastSeenKey) == nil else { return }
        defaults.set(isExistingInstall ? "0" : currentVersion, forKey: lastSeenKey)
    }

    static func lastSeen(defaults: UserDefaults) -> String {
        defaults.string(forKey: lastSeenKey) ?? "0"
    }

    static func markSeen(_ version: String, defaults: UserDefaults) {
        defaults.set(version, forKey: lastSeenKey)
        UpdateNotesQueue.clear(defaults: defaults)
    }
}

nonisolated enum VersionOrder {
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
    }
}
