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
        // 앱내 로그인은 외부 브라우저/CLI 계정과 섞이지 않도록 창 단위 임시 세션만 사용합니다.
        config.websiteDataStore = .nonPersistent()

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
