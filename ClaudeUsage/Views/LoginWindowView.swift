//
//  LoginWindowView.swift
//  ClaudeUsage
//
//  Claude 로그인 윈도우 컨테이너
//

import SwiftUI

struct LoginWindowView: View {
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loginSuccess = false

    var onSessionKeyFound: (String) -> Void
    var onCancel: () -> Void

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
                }
                Spacer()
                if loginSuccess {
                    Label("로그인 성공!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

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
                        loginSuccess = true
                        onSessionKeyFound(key)
                    },
                    onLoadingChanged: { loading in
                        isLoading = loading
                    },
                    onError: { error in
                        errorMessage = error
                    }
                )

                if loginSuccess {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("세션 키를 성공적으로 가져왔습니다")
                            .font(.headline)
                        Text("이 창은 자동으로 닫힙니다")
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
                Text("claude.ai에 로그인하면 세션 키가 자동으로 추출됩니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 480, height: 640)
    }
}
