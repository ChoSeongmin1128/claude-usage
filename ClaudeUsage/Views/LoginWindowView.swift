import AppKit
import SwiftUI

/// Claude 로그인 윈도우.
///
/// **설계 원칙 (Jakob's Law, Hick's Law)**:
/// - 한 화면에서 한 결정만 요구한다.
/// - 인증 모델(Chrome 추출 / Claude Code CLI / 임베드 웹뷰 / 수동 입력) 별로
///   별도 step 으로 분기해 사용자가 어디서 시작해야 할지 의심하지 않게 한다.
/// - "권장 경로 안내 문구" 같은 메타 설명은 각 카드의 부제로 흡수.
struct LoginWindowView: View {
    // MARK: - Public Surface

    var clearOnOpen: Bool
    var startChromeImportOnOpen: Bool
    var onSessionKeyFound: (String, String?, ClaudeAccountSource?, String?) async throws -> Void
    var onActivateCLI: () async throws -> ActivationSummary
    var onLoadCLIPreview: () async -> CLIPreview?
    var onOpenAdvancedSettings: () -> Void
    var onCancel: () -> Void

    init(
        clearOnOpen: Bool = false,
        startChromeImportOnOpen: Bool = false,
        onSessionKeyFound: @escaping (String, String?, ClaudeAccountSource?, String?) async throws -> Void,
        onActivateCLI: @escaping () async throws -> ActivationSummary,
        onLoadCLIPreview: @escaping () async -> CLIPreview?,
        onOpenAdvancedSettings: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.clearOnOpen = clearOnOpen
        self.startChromeImportOnOpen = startChromeImportOnOpen
        self.onSessionKeyFound = onSessionKeyFound
        self.onActivateCLI = onActivateCLI
        self.onLoadCLIPreview = onLoadCLIPreview
        self.onOpenAdvancedSettings = onOpenAdvancedSettings
        self.onCancel = onCancel
        self._clearTriggerSeed = State(initialValue: clearOnOpen ? 1 : 0)
    }

    // MARK: - Types

    /// 로그인 흐름 상태. View 의 분기 단일 진실의 출처.
    enum Step: Equatable {
        case methodSelection
        case chromeImporting
        case chromeCandidates([ClaudeBrowserImportedSession])
        case chromeUnavailable(message: String)
        case embeddedWeb
        case cliActivating
        case success(ActivationSummary)
        case failure(FailureContext)
    }

    struct ActivationSummary: Equatable, Sendable {
        let title: String
        let detail: String?
        let methodLabel: String

        nonisolated init(title: String, detail: String? = nil, methodLabel: String) {
            self.title = title
            self.detail = detail
            self.methodLabel = methodLabel
        }
    }

    struct CLIPreview: Equatable, Sendable {
        let email: String?
        let organizationName: String?
        let planLabel: String?

        nonisolated init(email: String? = nil, organizationName: String? = nil, planLabel: String? = nil) {
            self.email = email
            self.organizationName = organizationName
            self.planLabel = planLabel
        }

        nonisolated var subtitleLine: String? {
            let parts = [email, organizationName].compactMap { $0?.isEmpty == false ? $0 : nil }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    /// failure 화면에서 "다시 시도" 버튼이 어디로 돌려보낼지 가리키는 식별자.
    /// Step 자체를 담으면 Step → FailureContext → Step 재귀로 value type 무한 크기가 되므로,
    /// 가벼운 case enum 으로 분리한다.
    enum RetryDestination: Equatable {
        case methodSelection
        case chromeImport
        case embeddedWeb
        case cliActivation
    }

    struct FailureContext: Equatable {
        let message: String
        let retryDestination: RetryDestination?
    }

    // MARK: - State

    @State private var step: Step = .methodSelection
    @State private var cliPreview: CLIPreview?
    @State private var didLoadCLIPreview = false
    @State private var didStartOnAppearFlow = false
    @State private var clearTriggerSeed: Int
    @State private var embeddedStatusMessage: String?
    @State private var embeddedErrorMessage: String?
    @State private var isEmbeddedActivating = false

    private let chromeImporter = ClaudeChromeCookieImportService()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerBar
        }
        .frame(width: 720, height: 600)
        .onAppear {
            guard !didStartOnAppearFlow else { return }
            didStartOnAppearFlow = true
            Task { await preloadCLIPreviewIfNeeded() }
            applyOpenIntent()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if canGoBack {
                Button(action: { goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("뒤로")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .embeddedWeb = step, isEmbeddedActivating {
                ProgressView()
                    .controlSize(.small)
                Text("Claude 사용량 조회 확인 중...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var canGoBack: Bool {
        switch step {
        case .methodSelection: return false
        case .success: return false
        default: return true
        }
    }

    private var headerTitle: String {
        switch step {
        case .methodSelection: return "Claude 로그인"
        case .chromeImporting, .chromeCandidates, .chromeUnavailable: return "Chrome 프로필에서 가져오기"
        case .embeddedWeb: return "Claude.ai에서 직접 로그인"
        case .cliActivating: return "Claude Code 로그인 사용"
        case .success: return "연결 완료"
        case .failure: return "로그인 실패"
        }
    }

    private var headerSubtitle: String? {
        switch step {
        case .methodSelection: return "로그인 방법을 선택해 주세요"
        case .chromeImporting: return "Chrome에 저장된 Claude 로그인을 찾는 중..."
        case .chromeCandidates(let list): return "이 앱에서 사용할 계정을 선택해 주세요 (\(list.count)개)"
        case .chromeUnavailable: return "Chrome에서 가져올 수 없습니다"
        case .embeddedWeb: return "로그인이 끝나면 자동으로 가져옵니다"
        case .cliActivating: return "터미널 인증 정보를 사용 중..."
        case .success: return "사용량 조회가 확인되었습니다"
        case .failure: return nil
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button("고급 설정") {
                onOpenAdvancedSettings()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button("취소") { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content router

    @ViewBuilder
    private var contentArea: some View {
        switch step {
        case .methodSelection:
            methodSelectionView
        case .chromeImporting:
            chromeImportingView
        case .chromeCandidates(let candidates):
            chromeCandidatesView(candidates)
        case .chromeUnavailable(let message):
            chromeUnavailableView(message: message)
        case .embeddedWeb:
            embeddedWebView
        case .cliActivating:
            cliActivatingView
        case .success(let summary):
            successView(summary)
        case .failure(let context):
            failureView(context)
        }
    }

    // MARK: - Step 1: 방법 선택

    private var methodSelectionView: some View {
        ScrollView {
            VStack(spacing: 12) {
                methodCard(
                    icon: "globe",
                    iconTint: .blue,
                    title: "Chrome 프로필에서 가져오기",
                    subtitle: "Chrome에 이미 로그인된 Claude 계정을 자동으로 가져옵니다",
                    badge: "권장",
                    action: { startChromeImport() }
                )

                // v2.2.0: "Claude Code 로그인 사용" 카드는 의도적으로 제거.
                // /api/oauth/usage 경로 비활성화에 따라 CLI OAuth 자격으로 로그인해도
                // 사용량 조회가 안 되므로 옵션 자체를 노출하지 않는다. CLI 사용자도
                // Claude.ai 로그인으로 통일.

                methodCard(
                    icon: "key.horizontal",
                    iconTint: .orange,
                    title: "Claude.ai 에서 직접 로그인",
                    subtitle: "앱 안에서 Claude.ai 를 열어 로그인합니다",
                    badge: nil,
                    action: { startEmbeddedWeb() }
                )

                Button(action: { onOpenAdvancedSettings() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.adjustable")
                            .imageScale(.small)
                        Text("고급: sessionKey 직접 입력")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private var cliCardSubtitle: String {
        if let preview = cliPreview, let line = preview.subtitleLine {
            return "\(line) · 터미널 인증을 그대로 사용합니다"
        }
        if cliPreview != nil {
            return "터미널의 `claude login` 인증을 그대로 사용합니다"
        }
        if !didLoadCLIPreview {
            return "Claude Code 인증 정보를 찾는 중..."
        }
        return "터미널 인증 정보를 찾지 못했습니다"
    }

    private func methodCard(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        badge: String?,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isEnabled ? iconTint : Color.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(isEnabled ? Color.primary : .secondary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isEnabled, let disabledReason {
                        Text(disabledReason)
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                            .padding(.top, 2)
                    }
                }

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(isEnabled ? 0.6 : 0.3))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Step 2A: Chrome 추출

    private var chromeImportingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Chrome 프로필을 확인하고 있습니다...")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func chromeCandidatesView(_ candidates: [ClaudeBrowserImportedSession]) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("어떤 Chrome 프로필의 로그인을 사용할까요?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                ForEach(candidates) { candidate in
                    Button(action: { activateChrome(candidate: candidate) }) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.readableProfileName)
                                    .font(.subheadline.weight(.semibold))
                                Text(candidate.sourceDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private func chromeUnavailableView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Chrome에서 가져올 수 없습니다")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("Chrome에서 Claude 열기") {
                    openChromeForClaude()
                }
                Button("다른 방법으로 로그인") {
                    step = .methodSelection
                }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 2B: 임베드 웹뷰

    private var embeddedWebView: some View {
        ZStack {
            LoginWebView(
                onSessionKeyFound: { key in
                    activateEmbeddedSessionKey(key)
                },
                onLoadingChanged: { _ in },
                onError: { message in
                    embeddedErrorMessage = message
                },
                onStatusChanged: { status in
                    embeddedStatusMessage = status
                },
                clearTrigger: clearTriggerSeed
            )

            if isEmbeddedActivating {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView("Claude 사용량 조회 확인 중...")
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .bottom) {
            if let embeddedErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(embeddedErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("닫기") { self.embeddedErrorMessage = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.16))
            }
        }
    }

    // MARK: - Step 2C: CLI 활성화

    private var cliActivatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Claude Code 인증을 활성화하고 사용량을 확인하는 중...")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: 결과

    private func successView(_ summary: ActivationSummary) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.green)
            Text(summary.title)
                .font(.title3.weight(.semibold))
            if let detail = summary.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Text(summary.methodLabel)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
            Button("완료") { onCancel() }
                .controlSize(.large)
                .padding(.top, 8)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func failureView(_ context: FailureContext) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.red)
            Text("로그인을 완료하지 못했습니다")
                .font(.headline)
            Text(context.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                if let destination = context.retryDestination {
                    Button("다시 시도") { retry(to: destination) }
                        .keyboardShortcut(.defaultAction)
                }
                Button("다른 방법으로 로그인") {
                    step = .methodSelection
                }
                Button("고급 설정") {
                    onOpenAdvancedSettings()
                }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step transitions

    private func goBack() {
        // 단순한 룰: 어디서든 뒤로 → 방법 선택. 사용자가 길을 잃지 않도록 단일 anchor 유지.
        step = .methodSelection
        embeddedErrorMessage = nil
        embeddedStatusMessage = nil
        isEmbeddedActivating = false
    }

    private func applyOpenIntent() {
        if startChromeImportOnOpen {
            startChromeImport()
        }
    }

    private func startChromeImport() {
        embeddedErrorMessage = nil
        step = .chromeImporting
        Task.detached(priority: .userInitiated) {
            let outcome: Result<ClaudeBrowserImportOutcome, Error>
            do {
                outcome = .success(try chromeImporter.attemptImport())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run { applyChromeOutcome(outcome) }
        }
    }

    @MainActor
    private func applyChromeOutcome(_ outcome: Result<ClaudeBrowserImportOutcome, Error>) {
        switch outcome {
        case .success(.importedSession(let session)):
            activateChrome(candidate: session)
        case .success(.importedSessionCandidates(let candidates)):
            if candidates.count == 1, let only = candidates.first {
                activateChrome(candidate: only)
            } else {
                step = .chromeCandidates(candidates)
            }
        case .success(.manualSessionKeyRequired(let message)):
            step = .chromeUnavailable(message: message)
        case .success(.unavailable(let message)):
            step = .chromeUnavailable(message: message)
        case .failure(let error):
            step = .chromeUnavailable(message: error.localizedDescription)
        }
    }

    private func activateChrome(candidate: ClaudeBrowserImportedSession) {
        let methodLabel = "Chrome 프로필"
        let detail = [candidate.accountEmail, candidate.readableProfileName]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")

        step = .cliActivating  // 공통 progress 표시 재사용 → 잠시 후 success/failure 로 교체
        Task {
            do {
                try await onSessionKeyFound(
                    candidate.sessionKey,
                    candidate.displayName,
                    .chromeProfile,
                    candidate.sourceDetail
                )
                await MainActor.run {
                    step = .success(ActivationSummary(
                        title: "Chrome 프로필 로그인을 연결했습니다",
                        detail: detail.isEmpty ? nil : detail,
                        methodLabel: methodLabel))
                }
            } catch {
                await MainActor.run {
                    step = .failure(FailureContext(
                        message: error.localizedDescription,
                        retryDestination: .chromeImport))
                }
            }
        }
    }

    private func startEmbeddedWeb() {
        embeddedErrorMessage = nil
        embeddedStatusMessage = nil
        clearTriggerSeed += 1  // 새 진입마다 쿠키 초기화 (clearOnOpen 효과)
        step = .embeddedWeb
    }

    private func activateEmbeddedSessionKey(_ key: String) {
        guard !isEmbeddedActivating else { return }
        isEmbeddedActivating = true
        Task {
            do {
                try await onSessionKeyFound(key, nil, .embeddedWebLogin, nil)
                await MainActor.run {
                    isEmbeddedActivating = false
                    step = .success(ActivationSummary(
                        title: "Claude.ai 로그인을 연결했습니다",
                        detail: nil,
                        methodLabel: "Claude.ai 직접 로그인"))
                }
            } catch {
                await MainActor.run {
                    isEmbeddedActivating = false
                    step = .failure(FailureContext(
                        message: error.localizedDescription,
                        retryDestination: .embeddedWeb))
                }
            }
        }
    }

    private func startCLIActivation() {
        step = .cliActivating
        Task {
            do {
                let summary = try await onActivateCLI()
                await MainActor.run { step = .success(summary) }
            } catch {
                await MainActor.run {
                    step = .failure(FailureContext(
                        message: error.localizedDescription,
                        retryDestination: .cliActivation))
                }
            }
        }
    }

    /// failure 화면에서 "다시 시도" 클릭 시, 어디로 돌려보낼지 결정하고 진입 부수효과를 발동한다.
    private func retry(to destination: RetryDestination) {
        switch destination {
        case .methodSelection:
            step = .methodSelection
        case .chromeImport:
            startChromeImport()
        case .embeddedWeb:
            startEmbeddedWeb()
        case .cliActivation:
            startCLIActivation()
        }
    }

    private func preloadCLIPreviewIfNeeded() async {
        if didLoadCLIPreview { return }
        let preview = await onLoadCLIPreview()
        await MainActor.run {
            self.cliPreview = preview
            self.didLoadCLIPreview = true
        }
    }

    private func openChromeForClaude() {
        let targetURL = URL(string: "https://claude.ai/settings/usage")!
        if let chromeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: chromeAppURL, configuration: configuration)
            return
        }
        NSWorkspace.shared.open(targetURL)
    }
}
