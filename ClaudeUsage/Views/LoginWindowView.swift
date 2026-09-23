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
    var startCLIActivationOnOpen: Bool
    var onSessionKeyFound: (String, String?, ClaudeAccountSource?, String?) async throws -> Void
    var onActivateCLI: () async throws -> ActivationSummary
    var onLoadCLIPreview: () async -> CLIPreview?
    var onOpenAdvancedSettings: () -> Void
    var onCancel: () -> Void

    init(
        clearOnOpen: Bool = false,
        startChromeImportOnOpen: Bool = false,
        startCLIActivationOnOpen: Bool = false,
        onSessionKeyFound: @escaping (String, String?, ClaudeAccountSource?, String?) async throws -> Void,
        onActivateCLI: @escaping () async throws -> ActivationSummary,
        onLoadCLIPreview: @escaping () async -> CLIPreview?,
        onOpenAdvancedSettings: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.clearOnOpen = clearOnOpen
        self.startChromeImportOnOpen = startChromeImportOnOpen
        self.startCLIActivationOnOpen = startCLIActivationOnOpen
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
    @State private var taskScope = LoginTaskScope()
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
        .frame(width: AppDesign.Window.login.width, height: AppDesign.Window.login.height)
        .onAppear {
            guard !didStartOnAppearFlow else { return }
            didStartOnAppearFlow = true
            applyOpenIntent()
        }
        .task {
            if !startCLIActivationOnOpen { await preloadCLIPreviewIfNeeded() }
        }
        .onDisappear { taskScope.cancel() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: AppDesign.Space.content) {
            if canGoBack {
                Button(action: { goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(AppDesign.Typography.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("뒤로")
            }

            VStack(alignment: .leading, spacing: AppDesign.Space.tight) {
                Text(headerTitle)
                    .font(AppDesign.Typography.headline)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .embeddedWeb = step, isEmbeddedActivating {
                ProgressView()
                    .controlSize(.small)
                Text("Claude 사용량 조회 확인 중...")
                    .font(AppDesign.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppDesign.Space.section)
        .padding(.vertical, AppDesign.Space.content)
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
        HStack(spacing: AppDesign.Space.label) {
            Button("고급 설정") {
                onOpenAdvancedSettings()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button("취소") { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, AppDesign.Space.section)
        .padding(.vertical, AppDesign.Space.label)
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
            VStack(spacing: AppDesign.Space.content) {
                methodCard(
                    icon: "globe",
                    iconTint: .blue,
                    title: "Chrome 프로필에서 가져오기",
                    subtitle: "Chrome의 Claude 로그인을 가져옵니다 · macOS 인증은 최대 한 번만 요청합니다",
                    badge: "권장",
                    action: { startChromeImport() }
                )

                methodCard(
                    icon: "terminal",
                    iconTint: .purple,
                    title: "Claude Code 로그인 사용",
                    subtitle: cliCardSubtitle,
                    badge: cliPreview == nil ? nil : "감지됨",
                    isEnabled: didLoadCLIPreview,
                    action: { startCLIActivation() }
                )

                methodCard(
                    icon: "key.horizontal",
                    iconTint: .orange,
                    title: "Claude.ai 에서 직접 로그인",
                    subtitle: "앱 안에서 Claude.ai 를 열어 로그인합니다",
                    badge: nil,
                    action: { startEmbeddedWeb() }
                )

                Button(action: { onOpenAdvancedSettings() }) {
                    HStack(spacing: AppDesign.Space.compact) {
                        Image(systemName: "wrench.adjustable")
                            .imageScale(.small)
                        Text("고급: sessionKey 직접 입력")
                            .font(AppDesign.Typography.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.top, AppDesign.Space.row)
            }
            .padding(AppDesign.Space.window)
        }
    }

    private var cliCardSubtitle: String {
        if let preview = cliPreview, let line = preview.subtitleLine {
            return "\(line) · 다시 연결할 때 macOS 인증이 한 번 필요할 수 있습니다"
        }
        if cliPreview != nil {
            return "터미널 인증 사용 · 다시 연결할 때 macOS 인증이 한 번 필요할 수 있습니다"
        }
        if !didLoadCLIPreview {
            return "Claude Code 인증 정보를 찾는 중..."
        }
        return "클릭해 터미널 인증을 확인합니다 · 처음 연결할 때 macOS 인증이 한 번 필요할 수 있습니다"
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
            HStack(alignment: .top, spacing: AppDesign.Space.card) {
                Image(systemName: icon)
                    .font(AppDesign.Typography.title2)
                    .foregroundStyle(isEnabled ? iconTint : Color.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: AppDesign.Space.compact) {
                    HStack(spacing: AppDesign.Space.control) {
                        Text(title)
                            .font(AppDesign.Typography.headline)
                            .foregroundStyle(isEnabled ? Color.primary : .secondary)
                        if let badge {
                            Text(badge)
                                .font(AppDesign.Typography.caption2.weight(.semibold))
                                .padding(.horizontal, AppDesign.Space.control)
                                .padding(.vertical, AppDesign.Space.tight)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    Text(subtitle)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isEnabled, let disabledReason {
                        Text(disabledReason)
                            .font(AppDesign.Typography.caption2)
                            .foregroundStyle(Color.orange)
                            .padding(.top, AppDesign.Space.tight)
                    }
                }

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(AppDesign.Typography.caption)
                    .padding(.top, AppDesign.Space.control)
            }
            .padding(AppDesign.Space.card)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                    .fill(isEnabled ? AppDesign.Surface.strongGroup : AppDesign.Surface.disabledGroup)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Step 2A: Chrome 추출

    private var chromeImportingView: some View {
        VStack(spacing: AppDesign.Space.section) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Chrome 프로필을 확인하고 있습니다...")
                .font(AppDesign.Typography.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func chromeCandidatesView(_ candidates: [ClaudeBrowserImportedSession]) -> some View {
        ScrollView {
            VStack(spacing: AppDesign.Space.row) {
                Text("어떤 Chrome 프로필의 로그인을 사용할까요?")
                    .font(AppDesign.Typography.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppDesign.Space.compact)

                ForEach(candidates) { candidate in
                    Button(action: { activateChrome(candidate: candidate) }) {
                        HStack(spacing: AppDesign.Space.content) {
                            Image(systemName: "person.crop.circle")
                                .font(AppDesign.Typography.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: AppDesign.Space.micro) {
                                Text(candidate.readableProfileName)
                                    .font(AppDesign.Typography.subheadline.weight(.semibold))
                                Text(candidate.sourceDetail)
                                    .font(AppDesign.Typography.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(AppDesign.Typography.caption)
                        }
                        .padding(AppDesign.Space.content)
                        .background(
                            RoundedRectangle(cornerRadius: AppDesign.Radius.group)
                                .fill(AppDesign.Surface.strongGroup)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppDesign.Space.window)
        }
    }

    private func chromeUnavailableView(message: String) -> some View {
        VStack(spacing: AppDesign.Space.section) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(AppDesign.Typography.setupIcon)
                .foregroundStyle(.secondary)
            Text("Chrome에서 가져올 수 없습니다")
                .font(AppDesign.Typography.headline)
            Text(message)
                .font(AppDesign.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppDesign.Space.page)
            HStack(spacing: AppDesign.Space.label) {
                Button("Chrome에서 Claude 열기") {
                    openChromeForClaude()
                }
                Button("다른 방법으로 로그인") {
                    step = .methodSelection
                }
            }
            .padding(.top, AppDesign.Space.row)
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
                    .padding(AppDesign.Space.window)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AppDesign.Radius.card))
            }
        }
        .overlay(alignment: .bottom) {
            if let embeddedErrorMessage {
                HStack(spacing: AppDesign.Space.row) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(embeddedErrorMessage)
                        .font(AppDesign.Typography.caption)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button("닫기") { self.embeddedErrorMessage = nil }
                        .font(AppDesign.Typography.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, AppDesign.Space.content)
                .padding(.vertical, AppDesign.Space.row)
                .background(Color.orange.opacity(0.16))
            }
        }
    }

    // MARK: - Step 2C: CLI 활성화

    private var cliActivatingView: some View {
        VStack(spacing: AppDesign.Space.section) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Claude Code 인증을 활성화하고 사용량을 확인하는 중...")
                .font(AppDesign.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppDesign.Space.page)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: 결과

    private func successView(_ summary: ActivationSummary) -> some View {
        VStack(spacing: AppDesign.Space.section) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(AppDesign.Typography.successIcon)
                .foregroundStyle(Color.green)
            Text(summary.title)
                .font(AppDesign.Typography.title3.weight(.semibold))
            if let detail = summary.detail {
                Text(detail)
                    .font(AppDesign.Typography.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppDesign.Space.page)
            }
            Text(summary.methodLabel)
                .font(AppDesign.Typography.caption)
                .padding(.horizontal, AppDesign.Space.label)
                .padding(.vertical, AppDesign.Space.compact)
                .background(Color.green.opacity(0.12), in: Capsule())
                .foregroundStyle(.green)
            Button("완료") { onCancel() }
                .controlSize(.large)
                .padding(.top, AppDesign.Space.row)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func failureView(_ context: FailureContext) -> some View {
        VStack(spacing: AppDesign.Space.section) {
            Spacer()
            Image(systemName: "xmark.octagon.fill")
                .font(AppDesign.Typography.failureIcon)
                .foregroundStyle(Color.red)
            Text("로그인을 완료하지 못했습니다")
                .font(AppDesign.Typography.headline)
            Text(context.message)
                .font(AppDesign.Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppDesign.Space.page)
            HStack(spacing: AppDesign.Space.label) {
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
            .padding(.top, AppDesign.Space.row)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step transitions

    private func goBack() {
        taskScope.cancel()
        // 단순한 룰: 어디서든 뒤로 → 방법 선택. 사용자가 길을 잃지 않도록 단일 anchor 유지.
        step = .methodSelection
        embeddedErrorMessage = nil
        embeddedStatusMessage = nil
        isEmbeddedActivating = false
    }

    private func applyOpenIntent() {
        if startCLIActivationOnOpen {
            startCLIActivation()
        } else if startChromeImportOnOpen {
            startChromeImport()
        }
    }

    private func startChromeImport() {
        embeddedErrorMessage = nil
        step = .chromeImporting
        let importer = chromeImporter
        taskScope.run {
            await Task.detached(priority: .userInitiated) {
                Result { try importer.attemptImport() }
            }.value
        } apply: { outcome in
            applyChromeOutcome(outcome)
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
        runActivation(retryDestination: .chromeImport) {
            try await onSessionKeyFound(
                candidate.sessionKey, candidate.displayName, .chromeProfile, candidate.sourceDetail)
            return ActivationSummary(
                title: "Chrome 프로필 로그인을 연결했습니다",
                detail: detail.isEmpty ? nil : detail, methodLabel: methodLabel)
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
        runActivation(retryDestination: .embeddedWeb) {
            try await onSessionKeyFound(key, nil, .embeddedWebLogin, nil)
            return ActivationSummary(title: "Claude.ai 로그인을 연결했습니다", methodLabel: "Claude.ai 직접 로그인")
        }
    }

    private func startCLIActivation() {
        step = .cliActivating
        runActivation(retryDestination: .cliActivation) {
            try await onActivateCLI()
        }
    }

    private func runActivation(
        retryDestination: RetryDestination, operation: @escaping @MainActor () async throws -> ActivationSummary
    ) {
        taskScope.run {
            do { return Result<ActivationSummary, Error>.success(try await operation()) } catch {
                return Result<ActivationSummary, Error>.failure(error)
            }
        } apply: { result in
            isEmbeddedActivating = false
            switch result {
            case .success(let summary): step = .success(summary)
            case .failure(let error):
                step = .failure(FailureContext(message: error.localizedDescription, retryDestination: retryDestination))
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
        guard !Task.isCancelled else { return }
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
