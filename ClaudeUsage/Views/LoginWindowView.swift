import AppKit
import SwiftUI

struct LoginWindowView: View {
    private let chromeImporter = ClaudeChromeCookieImportService()

    @State private var isLoading = false
    @State private var isImportingFromChrome = false
    @State private var isActivatingSession = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var loginSuccess = false
    @State private var clearTrigger: Int
    @State private var chromeSessionCandidates: [ClaudeBrowserImportedSession] = []

    var clearOnOpen: Bool
    var onSessionKeyFound: (String, String?, ClaudeAccountSource?, String?) async throws -> Void
    var onOpenAdvancedSettings: () -> Void
    var onCancel: () -> Void

    init(
        clearOnOpen: Bool = false,
        onSessionKeyFound: @escaping (String, String?, ClaudeAccountSource?, String?) async throws -> Void,
        onOpenAdvancedSettings: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.clearOnOpen = clearOnOpen
        self._clearTrigger = State(initialValue: clearOnOpen ? 1 : 0)
        self.onSessionKeyFound = onSessionKeyFound
        self.onOpenAdvancedSettings = onOpenAdvancedSettings
        self.onCancel = onCancel
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("권장 경로")
                .font(.caption)
                .fontWeight(.semibold)
            Text("먼저 `Chrome에서 가져오기`를 시도하고, 안 되면 `Chrome 로그인 열기`나 `고급 설정`을 사용해 주세요.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
        .cornerRadius(8)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 상단 바
            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("로딩 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isImportingFromChrome {
                    ProgressView()
                        .controlSize(.small)
                    Text("Chrome에서 가져오는 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isActivatingSession {
                    ProgressView()
                        .controlSize(.small)
                    Text("Claude 사용량 조회를 확인하는 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let status = statusMessage, !loginSuccess {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loginSuccess {
                    Label("사용량 조회 확인됨", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.bold())
                } else {
                    Button(action: {
                        clearTrigger += 1
                        loginSuccess = false
                        isActivatingSession = false
                        statusMessage = "로그인 상태를 새로 시작합니다"
                    }) {
                        Label("초기화", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("로그인 정보를 초기화하고 다른 계정으로 로그인")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            guidanceCard
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if let error = errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("고급 설정") {
                        onOpenAdvancedSettings()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Button("닫기") { errorMessage = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            if !chromeSessionCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chrome에서 여러 Claude 로그인을 찾았습니다")
                        .font(.subheadline.weight(.semibold))
                    Text("현재 앱에서 사용할 계정을 선택하면 실제 사용량 조회를 확인한 뒤 저장합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(chromeSessionCandidates) { candidate in
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.readableProfileName)
                                    .font(.subheadline)
                                Text(candidate.sourceDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("이 계정 사용") {
                                chromeSessionCandidates = []
                                activateSessionKey(
                                    candidate.sessionKey,
                                    displayName: candidate.displayName,
                                    source: .chromeProfile,
                                    sourceDetail: candidate.sourceDetail
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
            }

            // 웹뷰
            ZStack {
                LoginWebView(
                    onSessionKeyFound: { key in
                        activateSessionKey(key, source: .embeddedWebLogin)
                    },
                    onLoadingChanged: { loading in
                        isLoading = loading
                    },
                    onError: { error in
                        errorMessage = error
                    },
                    onStatusChanged: { status in
                        statusMessage = status
                    },
                    clearTrigger: clearTrigger
                )

                if loginSuccess {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Claude 사용량 조회 확인됨")
                            .font(.headline)
                        Text("실제 조회가 성공해 브라우저 로그인 값을 저장했습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                }
            }

            Divider()

            // 하단 바
            HStack {
                Button("Chrome에서 가져오기") {
                    importFromChrome()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isImportingFromChrome || isActivatingSession || loginSuccess)
                Spacer()
                Button("Chrome 로그인 열기") {
                    openChromeForClaude()
                }
                .disabled(isLoading || isImportingFromChrome || isActivatingSession || loginSuccess)
                Button("고급 설정") {
                    onOpenAdvancedSettings()
                }
                .disabled(isLoading || isImportingFromChrome || isActivatingSession || loginSuccess)
                Button("취소") { onCancel() }
                    .disabled(isActivatingSession)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 800, height: 700)
    }

    private func activateSessionKey(
        _ key: String,
        displayName: String? = nil,
        source: ClaudeAccountSource? = .embeddedWebLogin,
        sourceDetail: String? = nil
    ) {
        errorMessage = nil
        statusMessage = "브라우저 로그인 값을 확인했습니다"
        isActivatingSession = true

        Task {
            do {
                try await onSessionKeyFound(key, displayName, source, sourceDetail)
                await MainActor.run {
                    self.isActivatingSession = false
                    self.loginSuccess = true
                    self.statusMessage = "Claude 사용량 조회가 확인됐습니다"
                }
            } catch {
                await MainActor.run {
                    self.isActivatingSession = false
                    self.loginSuccess = false
                    self.statusMessage = "Claude 사용량 조회에 실패했습니다"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importFromChrome() {
        errorMessage = nil
        statusMessage = "Chrome 로그인 상태를 확인하는 중..."
        chromeSessionCandidates = []
        isImportingFromChrome = true

        Task.detached(priority: .userInitiated) {
            let outcome: Result<ClaudeBrowserImportOutcome, Error>
            do {
                outcome = .success(try self.chromeImporter.attemptImport())
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                self.isImportingFromChrome = false
                switch outcome {
                case .success(.importedSession(let session)):
                    self.activateSessionKey(
                        session.sessionKey,
                        displayName: session.displayName,
                        source: .chromeProfile,
                        sourceDetail: session.sourceDetail
                    )
                case .success(.importedSessionCandidates(let candidates)):
                    self.statusMessage = "Chrome에서 \(candidates.count)개 로그인 후보를 찾았습니다."
                    self.chromeSessionCandidates = candidates
                case .success(.manualSessionKeyRequired(let message)):
                    self.statusMessage = "Chrome 로그인 후 다시 가져오거나 고급 설정을 사용해 주세요."
                    self.errorMessage = message
                case .success(.unavailable(let message)):
                    self.errorMessage = message
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openChromeForClaude() {
        let targetURL = URL(string: "https://claude.ai/settings/usage")!
        if let chromeAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([targetURL], withApplicationAt: chromeAppURL, configuration: configuration)
            statusMessage = "Chrome에서 claude.ai를 열었습니다. 로그인 후 다시 가져와 주세요."
            errorMessage = nil
            return
        }

        NSWorkspace.shared.open(targetURL)
        statusMessage = "브라우저에서 claude.ai를 열었습니다. 로그인 후 다시 가져와 주세요."
        errorMessage = nil
    }
}
