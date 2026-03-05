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
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let parent: LoginWebView
        private var sessionKeyExtracted = false
        private var loginDetected = false
        private var usageProbeTriggered = false
        var lastClearTrigger = 0
        private var popupWindow: NSWindow?
        private var popupWebView: WKWebView?
        private var observedCookieStores: [WKHTTPCookieStore] = []
        private var didLogCookieInventory = false

        init(parent: LoginWebView) {
            self.parent = parent
        }

        deinit {
            for store in observedCookieStores {
                store.remove(self)
            }
            popupWebView?.stopLoading()
        }

        func registerCookieStore(_ store: WKHTTPCookieStore) {
            let identifier = ObjectIdentifier(store)
            if observedCookieStores.contains(where: { ObjectIdentifier($0) == identifier }) {
                return
            }
            observedCookieStores.append(store)
            store.add(self)
        }

        func resetState() {
            sessionKeyExtracted = false
            loginDetected = false
            usageProbeTriggered = false
            didLogCookieInventory = false
            closePopup()
        }

        private func closePopup() {
            let wv = popupWebView
            let win = popupWindow
            popupWebView = nil
            popupWindow = nil
            wv?.stopLoading()
            win?.close()
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChanged(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChanged(false)

            guard !sessionKeyExtracted else { return }
            let isPopupWebView = (webView == popupWebView)

            // 1차: 쿠키 스토어에서 추출
            checkCookiesFromStore(webView: webView)

            // 로그인 후 메인 페이지로 이동한 경우
            if let url = webView.url?.absoluteString,
               url.contains("claude.ai") && !url.contains("/login") {
                if !loginDetected {
                    loginDetected = true
                    parent.onStatusChanged("로그인 감지됨, 세션 키 확인 중...")
                }

                // 로그인 완료 후 usage 페이지 강제 이동은 메인 WebView에서만 수행
                // (팝업 OAuth 진행 중에 실행되면 다시 로그인 화면으로 되돌아갈 수 있음)
                if !isPopupWebView,
                   !usageProbeTriggered, !url.contains("/settings/usage"),
                   let usageURL = URL(string: "https://claude.ai/settings/usage") {
                    usageProbeTriggered = true
                    parent.onStatusChanged("세션 확인 페이지로 이동 중...")
                    webView.load(URLRequest(url: usageURL))
                }

                // 2차: JavaScript로 추출 시도
                extractViaJavaScript(webView: webView)
                extractFromHTML(webView: webView)
                extractFromWebStorage(webView: webView)

                // 3차: 지연 재시도 (쿠키가 늦게 설정될 수 있음)
                scheduleRetryChecks(webView: webView)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            defer { decisionHandler(.allow) }
            guard !sessionKeyExtracted else { return }
            inspectRequestForSessionKey(navigationAction.request, source: "navigationAction")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            defer { decisionHandler(.allow) }
            guard !sessionKeyExtracted else { return }
            inspectResponseForSessionKey(navigationResponse.response, source: "navigationResponse")
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
            // 이미 팝업이 떠 있으면 새 창을 만들지 말고 기존 팝업을 재사용
            if let existingPopup = popupWebView {
                // 기존 팝업 내부에서 발생한 추가 팝업 요청만 같은 팝업에서 이어받고,
                // 메인 WebView에서 들어온 추가 요청은 현재 팝업 흐름을 덮어쓰지 않는다.
                if webView == existingPopup {
                    existingPopup.load(navigationAction.request)
                }
                popupWindow?.makeKeyAndOrderFront(nil)
                return nil
            }

            // 팝업 윈도우 생성 (Google OAuth 등)
            // 중요: WebKit 계약상 반드시 전달된 configuration으로 생성해야 한다.
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = webView.customUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            registerCookieStore(configuration.websiteDataStore.httpCookieStore)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            if let host = navigationAction.request.url?.host, !host.isEmpty {
                window.title = "로그인 - \(host)"
            } else {
                window.title = "로그인"
            }
            window.contentView = popup
            window.center()
            window.makeKeyAndOrderFront(nil)

            closePopup()
            popupWindow = window
            popupWebView = popup
            scheduleRetryChecks(webView: popup)

            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView == popupWebView {
                closePopup()
            }
        }

        // MARK: - WKHTTPCookieStoreObserver

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                self?.extractFromCookieStore(cookieStore)
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
                        if trimmed.lowercased().hasPrefix("sessionkey=") {
                            let value = String(trimmed.dropFirst("sessionKey=".count))
                            let normalized = self.normalizeTokenCandidate(value)
                            if self.looksReasonableSessionCookieValue(normalized) {
                                self.foundSessionKey(value, source: "JavaScript")
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

        /// 2차-C: local/sessionStorage 값에서 토큰 패턴 탐색
        private func extractFromWebStorage(webView: WKWebView) {
            guard !sessionKeyExtracted else { return }

            let js = """
            (() => {
              const dump = [];
              for (const store of [window.localStorage, window.sessionStorage]) {
                if (!store) continue;
                for (let i = 0; i < store.length; i++) {
                  const k = store.key(i);
                  if (!k) continue;
                  const v = store.getItem(k);
                  if (v) dump.push(`${k}=${v}`);
                }
              }
              return dump.join('\\n');
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.sessionKeyExtracted else { return }
                guard let storageDump = result as? String, !storageDump.isEmpty else { return }

                if let key = self.extractLikelySessionKey(from: storageDump) {
                    self.foundSessionKey(key, source: "WebStorage")
                    return
                }

                for line in storageDump.split(separator: "\n") {
                    let raw = String(line)
                    if raw.lowercased().contains("sessionkey"),
                       let maybe = raw.split(separator: "=", maxSplits: 1).last {
                        let candidate = self.normalizeTokenCandidate(String(maybe))
                        if self.looksReasonableSessionCookieValue(candidate) {
                            self.foundSessionKey(candidate, source: "WebStorage sessionKey")
                            return
                        }
                    }
                }
            }
        }

        /// 2차-B: 페이지 HTML에서 토큰 패턴 탐색
        private func extractFromHTML(webView: WKWebView) {
            guard !sessionKeyExtracted else { return }

            let js = "document.documentElement ? document.documentElement.outerHTML : ''"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self, !self.sessionKeyExtracted else { return }
                guard let html = result as? String else { return }
                if let key = self.extractLikelySessionKey(from: html) {
                    self.foundSessionKey(key, source: "HTML")
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
                    self.extractFromHTML(webView: webView)
                    self.extractFromWebStorage(webView: webView)
                }
            }
        }

        /// 쿠키 배열에서 세션 키 검색
        private func scanCookies(_ cookies: [HTTPCookie], source: String) {
            guard !sessionKeyExtracted else { return }

            let authCookies = cookies.filter {
                let domain = $0.domain.lowercased()
                return domain.contains("claude.ai") || domain.contains("anthropic.com")
            }

            // 1순위: name이 sessionKey면 형식 가정을 완화해서 우선 채택
            for cookie in authCookies {
                if cookie.name.caseInsensitiveCompare("sessionKey") == .orderedSame {
                    let normalized = normalizeTokenCandidate(cookie.value)
                    if looksReasonableSessionCookieValue(normalized) {
                        foundSessionKey(normalized, source: "\(source) (sessionKey@\(cookie.domain))")
                        return
                    }
                }
            }

            // 2순위: 값 패턴 기반 탐색
            for cookie in authCookies {
                let normalized = normalizeTokenCandidate(cookie.value)
                if isLikelySessionKey(normalized) {
                    foundSessionKey(normalized, source: "\(source) (\(cookie.name)@\(cookie.domain))")
                    return
                }
            }

            // 디버그: 로그인 감지 후에도 못 찾으면 쿠키 목록 출력
            if loginDetected && !authCookies.isEmpty {
                let names = authCookies.map { "\($0.domain):\($0.name)" }.sorted()
                if !didLogCookieInventory {
                    didLogCookieInventory = true
                    Logger.debug("인증 쿠키 목록 (\(source)): \(names)")
                } else {
                    Logger.debug("Claude 쿠키 목록 (\(source)): \(authCookies.map { $0.name })")
                }
            }
        }

        private func foundSessionKey(_ value: String, source: String) {
            guard !sessionKeyExtracted else { return }
            sessionKeyExtracted = true

            // 팝업 WebView 즉시 중단 — 추가 콜백 방지
            popupWebView?.stopLoading()

            // 항상 async로 디스패치 — WebKit 콜백 중 UI 조작 시 데드락 방지
            DispatchQueue.main.async { [weak self] in
                Logger.info("세션 키 자동 추출 성공 (\(source))")
                self?.parent.onSessionKeyFound(value)
                // 팝업은 지연 후 닫기 (WebKit 프로세스 정리 시간 확보)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.closePopup()
                }
            }
        }

        private func inspectRequestForSessionKey(_ request: URLRequest, source: String) {
            if let cookieHeader = request.value(forHTTPHeaderField: "Cookie"),
               let key = extractSessionKeyFromCookieHeader(cookieHeader) {
                foundSessionKey(key, source: "\(source) header")
                return
            }

            if let url = request.url {
                if let key = extractLikelySessionKey(from: url.absoluteString) {
                    foundSessionKey(key, source: "\(source) url")
                    return
                }
            }
        }

        private func inspectResponseForSessionKey(_ response: URLResponse, source: String) {
            guard let http = response as? HTTPURLResponse else { return }
            for (key, value) in http.allHeaderFields {
                let headerKey = String(describing: key).lowercased()
                guard headerKey == "set-cookie" || headerKey == "set-cookie2" else { continue }
                let raw = String(describing: value)
                if let extracted = extractSessionKeyFromCookieHeader(raw) ?? extractLikelySessionKey(from: raw) {
                    foundSessionKey(extracted, source: "\(source) set-cookie")
                    return
                }
            }
        }

        private func extractSessionKeyFromCookieHeader(_ header: String) -> String? {
            let parts = header.split(separator: ";")
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().hasPrefix("sessionkey=") {
                    let value = String(trimmed.dropFirst("sessionKey=".count))
                    let normalized = normalizeTokenCandidate(value)
                    if looksReasonableSessionCookieValue(normalized) {
                        return normalized
                    }
                }
            }
            if let matched = extractLikelySessionKey(from: header) {
                return matched
            }
            return nil
        }

        private func normalizeTokenCandidate(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
            if let decoded = trimmed.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
            return trimmed
        }

        private func extractLikelySessionKey(from text: String) -> String? {
            // sk-ant-* 또는 sk-* 토큰 패턴을 우선 탐색
            if let range = text.range(of: #"sk-ant-[A-Za-z0-9\-_]+"#, options: .regularExpression) {
                return String(text[range])
            }
            if let range = text.range(of: #"sk-[A-Za-z0-9\-_]{20,}"#, options: .regularExpression) {
                return String(text[range])
            }
            return nil
        }

        private func isLikelySessionKey(_ value: String) -> Bool {
            let trimmed = normalizeTokenCandidate(value)
            guard trimmed.count >= 20 else { return false }
            if trimmed.range(of: #"^sk-ant-[A-Za-z0-9\-_]+$"#, options: .regularExpression) != nil {
                return true
            }
            if trimmed.range(of: #"^sk-[A-Za-z0-9\-_]{20,}$"#, options: .regularExpression) != nil {
                return true
            }
            return false
        }

        private func looksReasonableSessionCookieValue(_ value: String) -> Bool {
            let trimmed = normalizeTokenCandidate(value)
            guard trimmed.count >= 16, trimmed.count <= 1024 else { return false }
            guard !trimmed.contains(where: \.isWhitespace) else { return false }
            let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            return !hasControl
        }
    }
}
