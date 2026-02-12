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
    var onStatusChanged: (String) -> Void
    var clearTrigger: Int

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        config.websiteDataStore.httpCookieStore.add(context.coordinator)

        if let url = URL(string: "https://claude.ai/login") {
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
            let claudeRecords = records.filter { $0.displayName.contains("claude") }
            dataStore.removeData(ofTypes: dataTypes, for: claudeRecords) {
                DispatchQueue.main.async {
                    if let url = URL(string: "https://claude.ai/login") {
                        nsView.load(URLRequest(url: url))
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let parent: LoginWebView
        private var sessionKeyExtracted = false
        private var loginDetected = false
        var lastClearTrigger = 0
        private var popupWindow: NSWindow?
        private var popupWebView: WKWebView?

        init(parent: LoginWebView) {
            self.parent = parent
        }

        func resetState() {
            sessionKeyExtracted = false
            loginDetected = false
            closePopup()
        }

        private func closePopup() {
            popupWindow?.close()
            popupWindow = nil
            popupWebView = nil
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)

            guard !sessionKeyExtracted else { return }

            // 1차: 쿠키 스토어에서 추출
            checkCookiesFromStore(webView: webView)

            // 로그인 후 메인 페이지로 이동한 경우
            if let url = webView.url?.absoluteString,
               url.contains("claude.ai") && !url.contains("/login") {
                if !loginDetected {
                    loginDetected = true
                    parent.onStatusChanged("로그인 감지됨, 세션 키 확인 중...")
                }

                // 2차: JavaScript로 추출 시도
                extractViaJavaScript(webView: webView)

                // 3차: 지연 재시도 (쿠키가 늦게 설정될 수 있음)
                scheduleRetryChecks(webView: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChanged(false)
            let nsError = error as NSError
            if nsError.domain == "NSURLErrorDomain" && nsError.code == -999 { return }
            parent.onError("연결 실패: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onStatusChanged("페이지를 다시 로드합니다...")
            webView.reload()
        }

        // MARK: - WKUIDelegate

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Google OAuth 등 팝업이 필요한 경우 실제 윈도우 생성
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.customUserAgent = webView.customUserAgent

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "로그인"
            window.contentView = popup
            window.center()
            window.makeKeyAndOrderFront(nil)

            closePopup()
            popupWindow = window
            popupWebView = popup

            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView == popupWebView {
                closePopup()
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "확인")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "취소")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        // MARK: - WKHTTPCookieStoreObserver

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                self.extractFromCookieStore(cookieStore)
            }
        }

        // MARK: - Cookie Extraction (3중 탐색)

        /// 1차: WKHTTPCookieStore observer
        private func extractFromCookieStore(_ cookieStore: WKHTTPCookieStore) {
            guard !sessionKeyExtracted else { return }

            cookieStore.getAllCookies { [weak self] cookies in
                self?.scanCookies(cookies, source: "observer")
            }
        }

        /// 1차-B: navigation 완료 후 쿠키 스토어 직접 조회
        private func checkCookiesFromStore(webView: WKWebView) {
            guard !sessionKeyExtracted else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.scanCookies(cookies, source: "navigation")
            }
        }

        /// 2차: JavaScript document.cookie 파싱
        private func extractViaJavaScript(webView: WKWebView) {
            guard !sessionKeyExtracted else { return }

            let js = "document.cookie"
            webView.evaluateJavaScript(js) { [weak self] result, error in
                guard let self = self, !self.sessionKeyExtracted else { return }

                if let cookieString = result as? String {
                    // document.cookie에서 sessionKey 찾기
                    let pairs = cookieString.split(separator: ";")
                    for pair in pairs {
                        let trimmed = pair.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("sessionKey=") {
                            let value = String(trimmed.dropFirst("sessionKey=".count))
                            if value.hasPrefix("sk-ant-") {
                                self.foundSessionKey(value, source: "JavaScript")
                                return
                            }
                        }
                    }

                    // sessionKey 이름이 아니더라도 sk-ant- 패턴 검색
                    for pair in pairs {
                        let trimmed = pair.trimmingCharacters(in: .whitespaces)
                        if let eqIdx = trimmed.firstIndex(of: "=") {
                            let value = String(trimmed[trimmed.index(after: eqIdx)...])
                            if value.hasPrefix("sk-ant-") {
                                self.foundSessionKey(value, source: "JavaScript (패턴 매칭)")
                                return
                            }
                        }
                    }
                }

                if let error = error {
                    Logger.debug("JS 쿠키 읽기 실패: \(error.localizedDescription)")
                }
            }
        }

        /// 3차: 지연 재시도 (1초, 3초, 5초, 8초)
        private func scheduleRetryChecks(webView: WKWebView) {
            for delay in [1.0, 3.0, 5.0, 8.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.sessionKeyExtracted else { return }
                    self.checkCookiesFromStore(webView: webView)
                    self.extractViaJavaScript(webView: webView)
                }
            }
        }

        /// 쿠키 배열에서 세션 키 검색 (유연한 매칭)
        private func scanCookies(_ cookies: [HTTPCookie], source: String) {
            guard !sessionKeyExtracted else { return }

            let claudeCookies = cookies.filter { $0.domain.contains("claude.ai") }

            // 1순위: name이 sessionKey이고 sk-ant- 시작
            for cookie in claudeCookies {
                if cookie.name == "sessionKey" && cookie.value.hasPrefix("sk-ant-") {
                    foundSessionKey(cookie.value, source: "\(source) (sessionKey)")
                    return
                }
            }

            // 2순위: 아무 쿠키든 값이 sk-ant-sid01- 시작
            for cookie in claudeCookies {
                if cookie.value.hasPrefix("sk-ant-sid01-") {
                    foundSessionKey(cookie.value, source: "\(source) (\(cookie.name))")
                    return
                }
            }

            // 3순위: 아무 쿠키든 값이 sk-ant- 시작
            for cookie in claudeCookies {
                if cookie.value.hasPrefix("sk-ant-") {
                    foundSessionKey(cookie.value, source: "\(source) (\(cookie.name))")
                    return
                }
            }

            // 디버그: 로그인 감지 후에도 못 찾으면 쿠키 목록 출력
            if loginDetected && !claudeCookies.isEmpty {
                let names = claudeCookies.map { $0.name }
                Logger.debug("Claude 쿠키 목록 (\(source)): \(names)")
            }
        }

        private func foundSessionKey(_ value: String, source: String) {
            guard !sessionKeyExtracted else { return }
            sessionKeyExtracted = true
            closePopup()
            Logger.info("세션 키 자동 추출 성공 (\(source))")
            parent.onSessionKeyFound(value)
        }
    }
}
