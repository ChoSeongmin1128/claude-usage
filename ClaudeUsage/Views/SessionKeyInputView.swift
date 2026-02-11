//
//  SessionKeyInputView.swift
//  ClaudeUsage
//
//  Phase 3: 세션 키 입력 및 연결 테스트 UI
//

import SwiftUI

struct SessionKeyInputView: View {
    @State private var sessionKey: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting: Bool = false

    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 제목
            Text("세션 키 설정")
                .font(.title2)
                .fontWeight(.bold)

            // 안내 텍스트
            VStack(alignment: .leading, spacing: 8) {
                Text("Session Key 가져오는 방법:")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("1. claude.ai에 로그인합니다")
                    Text("2. 개발자 도구를 엽니다 (Cmd + Option + I)")
                    Text("3. Application 탭 → Cookies → https://claude.ai")
                    Text("4. sessionKey 값을 복사합니다")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Divider()

            // 세션 키 입력
            VStack(alignment: .leading, spacing: 8) {
                Text("세션 키")
                    .font(.headline)

                TextField("sk-ant-sid01-...", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                // 연결 테스트 결과
                if let result = testResult {
                    HStack(spacing: 6) {
                        switch result {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("연결 성공!")
                                .foregroundStyle(.green)
                        case .failure(let message):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.callout)
                }
            }

            Spacer()

            // 버튼 영역
            HStack {
                Button("연결 테스트") {
                    testConnection()
                }
                .disabled(sessionKey.isEmpty || isTesting)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if onCancel != nil {
                    Button("취소") {
                        onCancel?()
                    }
                }

                Button("저장") {
                    saveSessionKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(sessionKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
        .onAppear {
            // 기존 키가 있으면 마스킹하여 표시
            if let existingKey = KeychainManager.shared.load() {
                sessionKey = existingKey
            }
        }
    }

    private func testConnection() {
        guard !sessionKey.isEmpty else { return }

        isTesting = true
        testResult = nil

        Task {
            do {
                let service = ClaudeAPIService(sessionKey: sessionKey)
                let _ = try await service.fetchUsage()

                await MainActor.run {
                    testResult = .success
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func saveSessionKey() {
        guard !sessionKey.isEmpty else { return }

        do {
            try KeychainManager.shared.save(sessionKey)
            Logger.info("세션 키 저장 완료")
            onSave?(sessionKey)
        } catch {
            Logger.error("세션 키 저장 실패: \(error)")
            testResult = .failure("저장 실패: \(error.localizedDescription)")
        }
    }
}
