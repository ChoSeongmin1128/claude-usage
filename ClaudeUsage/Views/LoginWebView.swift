//
//  LoginWebView.swift
//  ClaudeUsage
//
//  WKWebView 기반 Claude 로그인 (세션 키 자동 추출)
//

import SwiftUI
import WebKit

struct LoginWebView: NSViewRepresentable {
    typealias Coordinator = LoginWebViewCoordinator

    var onSessionKeyFound: (String) -> Void
    var onLoadingChanged: (Bool) -> Void
    var onError: (String) -> Void
    var onStatusChanged: (String) -> Void
    var clearTrigger: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Google/Cloudflare 등 외부 인증 플로우 호환성을 위해 기본 스토어 사용
        // (필요 시 clearTrigger로 명시 초기화)
        config.websiteDataStore = .default()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        let cookieStore = config.websiteDataStore.httpCookieStore
        context.coordinator.registerCookieStore(cookieStore)

        // clearOnOpen일 때는 updateNSView에서 초기화 후 로드
        if clearTrigger == 0, let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard clearTrigger != context.coordinator.lastClearTrigger else { return }
        context.coordinator.lastClearTrigger = clearTrigger
        context.coordinator.resetState()

        let dataStore = nsView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {
                let cookieStorage = HTTPCookieStorage.shared
                cookieStorage.cookies?.forEach { cookieStorage.deleteCookie($0) }
                URLCache.shared.removeAllCachedResponses()
                DispatchQueue.main.async {
                    if let url = URL(string: "https://claude.ai/login") {
                        nsView.load(URLRequest(url: url))
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        LoginWebViewCoordinator(parent: self)
    }
}
