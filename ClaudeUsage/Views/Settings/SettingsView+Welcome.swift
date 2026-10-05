import AppKit
import SwiftUI

/// 처음 설정에서 확인 창 없이 알아낼 수 있는 것만 모은다.
struct OnboardingDetection: Equatable {
    var isLoaded = false
    var claudeCode = false
    var browser: ClaudeBrowserLoginFinding?
    var defaultBrowser: ClaudeBrowserFamily?
    var codex: CodexAuthStatus = .checking
    var agy: AntigravityAGYExecutableDiscoveryStatus = .notFound

    static func detect() async -> OnboardingDetection {
        _ = try? await CodexAuthManager.shared.loadSnapshot()
        let authJsonExists = CodexAuthManager.shared.authJsonExists
        let token = CodexAuthManager.shared.getToken()
        return await Task.detached(priority: .userInitiated) {
            OnboardingDetection(
                isLoaded: true,
                claudeCode: await ClaudeCodeLoginDetector.hasLogin(),
                browser: ClaudeBrowserLoginDetector.findLogin(),
                defaultBrowser: ClaudeBrowserLoginDetector.defaultBrowserFamily(),
                codex: CodexAuthStatusResolver.resolve(
                    isProviderEnabled: true, authJsonExists: authJsonExists, token: token,
                    isCodexInstalled: { CodexOwnerCLI.isAvailable() }),
                agy: AntigravityProductionExecutableCatalogResolver().resolve().agyExecutableStatus)
        }.value
    }
}

extension SettingsView {
    var welcomeSection: some View {
        let _ = runtimeEnvironmentRefreshTick
        let statuses = welcomeStatuses?() ?? [:]
        return WelcomeView(
            settings: settings, selectedProvider: $selectedProvider,
            statuses: statuses,
            rows: onboardingRows(statuses: statuses),
            display: providerMenuBarDisplaySection(for: selectedProvider),
            onDefer: {
                stopBrowserLoginWatch(); selectedPanel = .common
            },
            onFinish: {
                stopBrowserLoginWatch(); selectedPanel = .display
            }
        )
        .task { await refreshOnboardingDetection() }
        .sheet(item: $installGuide) { provider in
            OnboardingInstallGuide(provider: provider) {
                installGuide = nil
                Task { await refreshOnboardingDetection() }
            }
        }
    }

    func refreshOnboardingDetection() async {
        onboardingDetection = await onboardingDetector()
        autoConnectDetectedServices()
    }

    /// 확인 창 없이 쓸 수 있는 로그인(Claude Code 파일, Codex, AGY CLI)은 바로 켜고 사용량을 확인한다.
    /// 시작하기를 미루거나 마친 뒤에는 켜지 않는다. 사용자가 끈 서비스를 다시 켜지 않기 위해서다.
    private func autoConnectDetectedServices() {
        guard settings.welcomeState == .pending else { return }
        let detection = onboardingDetection
        var services: [PopoverService] = []
        if detection.claudeCode, ClaudeCodeLoginDetector.credentialFileExists() { services.append(.claude) }
        if detection.codex == .authenticated { services.append(.codex) }
        if case .verified = detection.agy { services.append(.antigravity) }
        for service in services where !settings.isProviderEnabled(service.providerKind) {
            settings.setProviderEnabled(true, for: service.providerKind)
            onVerifyService?(service)
        }
    }

    private func connect(_ provider: AppProviderKind) {
        settings.setProviderEnabled(true, for: provider)
        if provider == .codex { checkCodexAuth() }
        if let service = provider.runtimeService { onVerifyService?(service) }
    }

    private func onboardingRows(statuses: [AppProviderKind: WelcomeServiceStatus]) -> [OnboardingServiceRow] {
        AppProviderKind.allCases.map { provider in
            let status = statuses[provider]
            if settings.isProviderEnabled(provider), status == .verified {
                return OnboardingServiceRow(
                    provider: provider, status: "연결됨", tone: .connected,
                    detail: provider == .claude ? activeClaudeAccount()?.identity.email : nil)
            }
            if settings.isProviderEnabled(provider), status == .checking {
                return OnboardingServiceRow(provider: provider, status: "확인 중", tone: .checking)
            }
            guard onboardingDetection.isLoaded else {
                return OnboardingServiceRow(provider: provider, status: "찾는 중", tone: .checking)
            }
            switch provider {
            case .claude: return claudeOnboardingRow()
            case .codex: return codexOnboardingRow()
            case .antigravity: return antigravityOnboardingRow()
            }
        }
    }

    private func claudeOnboardingRow() -> OnboardingServiceRow {
        let detection = onboardingDetection
        let inApp = OnboardingServiceRow.Action(title: "앱에서 로그인") { onOpenEmbeddedLogin?() }
        if browserLoginWatch != nil {
            return OnboardingServiceRow(
                provider: .claude, status: "브라우저 로그인 기다리는 중", tone: .checking, secondary: inApp)
        }
        if settings.isProviderEnabled(.claude), hasReadyClaudeCredential {
            return OnboardingServiceRow(
                provider: .claude, status: "확인 전", tone: .ready,
                primary: .init(title: "사용량 확인") { connect(.claude) })
        }
        if detection.claudeCode {
            return OnboardingServiceRow(
                provider: .claude, status: "Claude Code에 로그인됨", tone: .ready,
                primary: .init(title: "연결") {
                    settings.setProviderEnabled(true, for: .claude)
                    onReconnectClaudeCode?()
                })
        }
        if let finding = detection.browser {
            let name = finding.family.displayName
            switch finding.presence {
            case .present:
                return OnboardingServiceRow(
                    provider: .claude, status: "\(name)에 로그인됨", tone: .ready,
                    primary: .init(title: "가져오기") {
                        settings.setProviderEnabled(true, for: .claude)
                        onImportClaudeFromBrowser?(finding.family)
                    },
                    secondary: inApp)
            case .needsFullDiskAccess:
                return OnboardingServiceRow(
                    provider: .claude, status: "\(name) 권한 필요", tone: .ready,
                    primary: .init(title: "가져오기") {
                        settings.setProviderEnabled(true, for: .claude)
                        onImportClaudeFromBrowser?(finding.family)
                    },
                    secondary: inApp)
            case .absent:
                break
            }
        }
        return OnboardingServiceRow(
            provider: .claude, status: "로그인 필요", tone: .missing,
            primary: .init(title: "브라우저에서 로그인") { startBrowserLogin(family: detection.defaultBrowser) },
            secondary: inApp)
    }

    private func codexOnboardingRow() -> OnboardingServiceRow {
        switch onboardingDetection.codex {
        case .authenticated:
            return OnboardingServiceRow(
                provider: .codex, status: "로그인됨", tone: .ready, primary: .init(title: "연결") { connect(.codex) })
        case .notInstalled:
            return OnboardingServiceRow(
                provider: .codex, status: "찾지 못함", tone: .missing,
                primary: .init(title: "설치 방법") { installGuide = .codex })
        case .notLoggedIn, .expired:
            return OnboardingServiceRow(
                provider: .codex, status: "로그인 필요", tone: .missing,
                primary: .init(title: "로그인 방법") { installGuide = .codex })
        case .checking:
            return OnboardingServiceRow(provider: .codex, status: "찾는 중", tone: .checking)
        }
    }

    private func antigravityOnboardingRow() -> OnboardingServiceRow {
        switch onboardingDetection.agy {
        case .verified:
            return OnboardingServiceRow(
                provider: .antigravity, status: "AGY CLI 설치됨", tone: .ready,
                primary: .init(title: "연결") { connect(.antigravity) })
        case .notFound, .rejected:
            return OnboardingServiceRow(
                provider: .antigravity, status: "찾지 못함", tone: .missing,
                primary: .init(title: "설치 방법") { installGuide = .antigravity })
        }
    }

    /// 기본 브라우저에서 claude.ai를 열고, 로그인 쿠키가 생기면 가져오기를 시작한다.
    private func startBrowserLogin(family: ClaudeBrowserFamily?) {
        stopBrowserLoginWatch()
        let url = URL(string: "https://claude.ai/login")!
        if let appURL = family?.bundleIdentifiers.lazy.compactMap({
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).first {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        guard let family else { return }
        browserLoginWatch = Task {
            let deadline = Date().addingTimeInterval(600)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(3))
                let presence = await Task.detached(priority: .utility) {
                    ClaudeBrowserLoginDetector.presence(in: family)
                }.value
                guard !Task.isCancelled else { return }
                if presence == .present {
                    browserLoginWatch = nil
                    settings.setProviderEnabled(true, for: .claude)
                    onImportClaudeFromBrowser?(family)
                    return
                }
            }
            browserLoginWatch = nil
        }
    }

    func stopBrowserLoginWatch() {
        browserLoginWatch?.cancel()
        browserLoginWatch = nil
    }
}

struct OnboardingInstallGuide: View {
    let provider: AppProviderKind
    let onDone: () -> Void

    private static let codexInstall = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    private static let agyInstall = "curl -fsSL https://antigravity.google/cli/install.sh | bash"

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Space.content) {
            switch provider {
            case .codex:
                Text("Codex가 필요합니다").font(AppDesign.Typography.headline)
                step("ChatGPT 앱 설치", "chatgpt.com/download 에서 받습니다. ChatGPT Classic 앱에는 Codex가 없습니다.") {
                    Link("다운로드 페이지", destination: URL(string: "https://chatgpt.com/download")!)
                }
                step("ChatGPT 앱에서 Codex 로그인", nil) { EmptyView() }
                Divider()
                Text("터미널을 쓴다면").font(AppDesign.Typography.subheadline.weight(.semibold))
                command(Self.codexInstall)
                step("codex 실행", "\"Sign in with ChatGPT\"를 고릅니다.") { EmptyView() }
                Text("Homebrew: brew install --cask codex").font(AppDesign.Typography.caption).foregroundStyle(
                    .secondary)
            case .antigravity:
                Text("AGY CLI가 필요합니다").font(AppDesign.Typography.headline)
                step("터미널에서 설치", nil) { EmptyView() }
                command(Self.agyInstall)
                step("agy 실행 후 로그인", "기본 브라우저가 열립니다.") {
                    Button("터미널 열기") {
                        if let terminal = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: "com.apple.Terminal")
                        {
                            NSWorkspace.shared.openApplication(
                                at: terminal, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            case .claude:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("닫기", action: onDone)
                Button("다시 찾기", action: onDone).buttonStyle(.borderedProminent)
            }
        }
        .padding(AppDesign.Space.window)
        .frame(width: 440)
    }

    private func step<Trailing: View>(_ title: String, _ detail: String?, @ViewBuilder trailing: () -> Trailing)
        -> some View
    {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(title).font(AppDesign.Typography.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(AppDesign.Typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(AppDesign.Space.row)
        .background(AppDesign.Surface.group, in: RoundedRectangle(cornerRadius: AppDesign.Radius.control))
    }
}

extension AppProviderKind: Identifiable {
    public var id: String { rawValue }
}
