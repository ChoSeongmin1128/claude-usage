//
//  LoginWebView.swift
//  ClaudeUsage
//
//  WKWebView 기반 Claude 로그인 (세션 키 자동 추출)
//

import SwiftUI
import WebKit

struct LoginWebView: NSViewRepresentable {
    var onSessionKeyFound: (String) -> Void
    var onLoadingChanged: (Bool) -> Void
    var onError: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        // 쿠키 변경 감지
        config.websiteDataStore.httpCookieStore.add(context.coordinator)

        // 로그인 페이지 로드
        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: LoginWebView
        private var sessionKeyExtracted = false

        init(parent: LoginWebView) {
            self.parent = parent
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)
            checkCookies(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            parent.onError("페이지 로드 실패: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            let nsError = error as NSError
            // 리다이렉트에 의한 취소는 무시
            if nsError.domain == "NSURLErrorDomain" && nsError.code == -999 { return }
            parent.onError("연결 실패: \(error.localizedDescription)")
        }

        // MARK: - WKHTTPCookieStoreObserver

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                self.extractSessionKey(from: cookieStore)
            }
        }

        // MARK: - Cookie Extraction

        private func extractSessionKey(from cookieStore: WKHTTPCookieStore) {
            guard !sessionKeyExtracted else { return }

            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.sessionKeyExtracted else { return }

                for cookie in cookies {
                    if cookie.name == "sessionKey",
                       cookie.value.hasPrefix("sk-ant-sid01-"),
                       cookie.domain.contains("claude.ai") {
                        self.sessionKeyExtracted = true
                        Logger.info("세션 키 자동 추출 성공")
                        self.parent.onSessionKeyFound(cookie.value)
                        return
                    }
                }
            }
        }

        private func checkCookies(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.sessionKeyExtracted else { return }

                for cookie in cookies {
                    if cookie.name == "sessionKey",
                       cookie.value.hasPrefix("sk-ant-sid01-"),
                       cookie.domain.contains("claude.ai") {
                        self.sessionKeyExtracted = true
                        Logger.info("세션 키 자동 추출 성공 (navigation 완료)")
                        self.parent.onSessionKeyFound(cookie.value)
                        return
                    }
                }
            }
        }
    }
}
