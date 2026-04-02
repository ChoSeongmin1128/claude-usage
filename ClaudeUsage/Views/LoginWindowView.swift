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

    var clearOnOpen: Bool
    var onSessionKeyFound: (String) async throws -> Void
    var onCancel: () -> Void

    init(clearOnOpen: Bool = false, onSessionKeyFound: @escaping (String) async throws -> Void, onCancel: @escaping () -> Void) {
        self.clearOnOpen = clearOnOpen
        self._clearTrigger = State(initialValue: clearOnOpen ? 1 : 0)
        self.onSessionKeyFound = onSessionKeyFound
        self.onCancel = onCancel
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("권장 경로")
                .font(.caption)
                .fontWeight(.semibold)
            Text("1. 먼저 `Chrome에서 가져오기`를 시도합니다.")
            Text("2. 실패하면 이 창에서 웹 로그인으로 sessionKey 자동 추출을 시도합니다.")
            Text("3. 계속 실패하면 `Chrome 열기`로 claude.ai에 로그인한 뒤 다시 가져오기를 누릅니다.")
            Text("4. 그래도 안 되면 설정의 고급 옵션에서 sessionKey 값만 직접 입력합니다.")
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
                    Text("세션 키 저장 및 반영 중...")
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
                    Label("세션 키 추출 완료!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.bold())
                } else {
                    Button(action: {
                        clearTrigger += 1
                        loginSuccess = false
                        isActivatingSession = false
                        statusMessage = "쿠키 초기화됨"
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
                    Button("닫기") { errorMessage = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }

            // 웹뷰
            ZStack {
                LoginWebView(
                    onSessionKeyFound: { key in
                        activateSessionKey(key)
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
                        Text("세션 키를 성공적으로 가져왔습니다")
                            .font(.headline)
                        Text("저장과 반영까지 완료했습니다")
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("기본 순서는 `Chrome에서 가져오기` → `웹 로그인 추출` → `수동 sessionKey`입니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Chrome 로그인 상태가 애매하면 먼저 `Chrome 열기`로 claude.ai를 연 뒤 다시 가져오기를 누르시는 편이 맞습니다")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Chrome 열기") {
                    openChromeForClaude()
                }
                .disabled(isLoading || isImportingFromChrome || isActivatingSession || loginSuccess)
                Button("Chrome에서 가져오기") {
                    importFromChrome()
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

    private func activateSessionKey(_ key: String) {
        errorMessage = nil
        statusMessage = "세션 키를 확인했습니다"
        isActivatingSession = true

        Task {
            do {
                try await onSessionKeyFound(key)
                await MainActor.run {
                    self.isActivatingSession = false
                    self.loginSuccess = true
                    self.statusMessage = "세션 키 저장과 반영이 완료됐습니다"
                }
            } catch {
                await MainActor.run {
                    self.isActivatingSession = false
                    self.loginSuccess = false
                    self.statusMessage = "세션 키 저장 또는 반영에 실패했습니다"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func importFromChrome() {
        errorMessage = nil
        statusMessage = "Chrome 프로필과 쿠키를 확인하는 중..."
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
                case .success(.importedSessionKey(let key)):
                    self.activateSessionKey(key)
                case .success(.manualSessionKeyRequired(let message)):
                    self.statusMessage = "Chrome 로그인 상태를 확인한 뒤 다시 가져오거나, 아래 웹 로그인으로 진행해 주세요."
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
            statusMessage = "Chrome에서 claude.ai를 열었습니다. 로그인 후 다시 가져오기를 눌러 주세요."
            errorMessage = nil
            return
        }

        NSWorkspace.shared.open(targetURL)
        statusMessage = "기본 브라우저로 claude.ai를 열었습니다. 로그인 후 다시 가져오기를 눌러 주세요."
        errorMessage = nil
    }
}
