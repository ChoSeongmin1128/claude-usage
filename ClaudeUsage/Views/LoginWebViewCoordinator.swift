import Foundation
import WebKit

final class LoginWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let parent: LoginWebView
    private let extractor = ClaudeSessionKeyExtractor()
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

    private enum StatusNotice {
        case loginDetected
        case probingSessionPage
        case reloadingPage

        var text: String {
            switch self {
            case .loginDetected:
                return "로그인 감지됨, 세션 키 확인 중..."
            case .probingSessionPage:
                return "세션 확인 페이지로 이동 중..."
            case .reloadingPage:
                return "페이지를 다시 로드합니다..."
            }
        }
    }

    private func report(_ notice: StatusNotice) {
        self.parent.onStatusChanged(notice.text)
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        parent.onLoadingChanged(true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        parent.onLoadingChanged(false)

        guard !sessionKeyExtracted else { return }
        let isPopupWebView = (webView == popupWebView)

        checkCookiesFromStore(webView: webView)
        handleAuthenticatedPage(webView: webView, isPopupWebView: isPopupWebView)
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
        self.report(.reloadingPage)
        webView.reload()
    }

    private func handleAuthenticatedPage(webView: WKWebView, isPopupWebView: Bool) {
        guard let url = webView.url?.absoluteString,
              url.contains("claude.ai"),
              !url.contains("/login") else {
            return
        }

        if !loginDetected {
            loginDetected = true
            self.report(.loginDetected)
        }

        if !isPopupWebView,
           !usageProbeTriggered,
           !url.contains("/settings/usage"),
           let usageURL = URL(string: "https://claude.ai/settings/usage") {
            usageProbeTriggered = true
            self.report(.probingSessionPage)
            webView.load(URLRequest(url: usageURL))
        }

        extractViaJavaScript(webView: webView)
        extractFromHTML(webView: webView)
        extractFromWebStorage(webView: webView)
        schedulePostLoginProbe(webView: webView)
        scheduleRetryChecks(webView: webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let existingPopup = popupWebView {
            if webView == existingPopup {
                existingPopup.load(navigationAction.request)
            }
            popupWindow?.makeKeyAndOrderFront(nil)
            return nil
        }

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

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.extractFromCookieStore(cookieStore)
        }
    }

    private func extractFromCookieStore(_ cookieStore: WKHTTPCookieStore) {
        guard !sessionKeyExtracted else { return }

        cookieStore.getAllCookies { [weak self] cookies in
            self?.scanCookies(cookies, source: "observer")
        }
    }

    private func checkCookiesFromStore(webView: WKWebView) {
        guard !sessionKeyExtracted else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            self?.scanCookies(cookies, source: "navigation")
        }
    }

    private func extractViaJavaScript(webView: WKWebView) {
        guard !sessionKeyExtracted else { return }

        webView.evaluateJavaScript("document.cookie") { [weak self] result, error in
            guard let self = self, !self.sessionKeyExtracted else { return }

            if let cookieString = result as? String,
               let key = self.extractor.extractSessionKey(fromCookieHeader: cookieString) {
                self.foundSessionKey(key, source: "JavaScript")
                return
            }

            if let error = error {
                Logger.debug("JS 쿠키 읽기 실패: \(error.localizedDescription)")
            }
        }
    }

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

            if let key = self.extractor.extractLikelySessionKey(from: storageDump) {
                self.foundSessionKey(key, source: "WebStorage")
                return
            }

            for line in storageDump.split(separator: "\n") {
                let raw = String(line)
                if raw.lowercased().contains("sessionkey"),
                   let maybe = raw.split(separator: "=", maxSplits: 1).last {
                    let candidate = self.extractor.normalizeTokenCandidate(String(maybe))
                    if self.extractor.looksReasonableSessionCookieValue(candidate) {
                        self.foundSessionKey(candidate, source: "WebStorage sessionKey")
                        return
                    }
                }
            }
        }
    }

    private func extractFromHTML(webView: WKWebView) {
        guard !sessionKeyExtracted else { return }

        webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { [weak self] result, _ in
            guard let self, !self.sessionKeyExtracted else { return }
            guard let html = result as? String else { return }
            if let key = self.extractor.extractLikelySessionKey(from: html) {
                self.foundSessionKey(key, source: "HTML")
            }
        }
    }

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

    private func schedulePostLoginProbe(webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, !self.sessionKeyExtracted else { return }
            self.checkCookiesFromStore(webView: webView)
            self.extractViaJavaScript(webView: webView)
            self.extractFromWebStorage(webView: webView)
        }
    }

    private func scanCookies(_ cookies: [HTTPCookie], source: String) {
        guard !sessionKeyExtracted else { return }

        let authCookies = cookies.filter {
            let domain = $0.domain.lowercased()
            return domain.contains("claude.ai") || domain.contains("anthropic.com")
        }

        if let extracted = self.extractor.extractSessionKey(from: authCookies) {
            self.foundSessionKey(
                extracted.value,
                source: "\(source) (\(extracted.matchedCookieName)@\(extracted.matchedDomain))")
            return
        }

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
        popupWebView?.stopLoading()

        DispatchQueue.main.async { [weak self] in
            Logger.info("세션 키 자동 추출 성공 (\(source))")
            self?.parent.onSessionKeyFound(value)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.closePopup()
            }
        }
    }

    private func inspectRequestForSessionKey(_ request: URLRequest, source: String) {
        if let cookieHeader = request.value(forHTTPHeaderField: "Cookie"),
           let key = self.extractor.extractSessionKey(fromCookieHeader: cookieHeader) {
            foundSessionKey(key, source: "\(source) header")
            return
        }

        if let url = request.url,
           let key = self.extractor.extractLikelySessionKey(from: url.absoluteString) {
            foundSessionKey(key, source: "\(source) url")
        }
    }

    private func inspectResponseForSessionKey(_ response: URLResponse, source: String) {
        guard let http = response as? HTTPURLResponse else { return }
        for (key, value) in http.allHeaderFields {
            let headerKey = String(describing: key).lowercased()
            guard headerKey == "set-cookie" || headerKey == "set-cookie2" else { continue }
            let raw = String(describing: value)
            if let extracted = self.extractor.extractSessionKey(fromCookieHeader: raw) ?? self.extractor.extractLikelySessionKey(from: raw) {
                foundSessionKey(extracted, source: "\(source) set-cookie")
                return
            }
        }
    }
}
