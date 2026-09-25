import Foundation
import UIKit
import WebKit

/// WebView 的状态机与全部导航逻辑。
///
/// 承担四件事：
/// 1. 加载目标地址，并把令牌用 `?token=` 传进去；
/// 2. 忽略 TLS 证书错误（`didReceive challenge`）；
/// 3. 失败时按 2s / 4s / 8s 自动重试，并把可读的错误暴露给界面；
/// 4. 补齐 WKWebView 默认不做的事：`confirm()` 等 JS 对话框、target=_blank、摄像头授权。
final class WebViewModel: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// 自动重试的最大次数。
    static let maxAutoRetry = 3

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var retryCountdown: Int = 0
    @Published private(set) var retryAttempt: Int = 0

    private(set) var target: ServerTarget?

    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var retryTimer: Timer?
    private var pendingTarget: ServerTarget?
    private var ignoreTLSErrors = true
    private var autoRetryEnabled = true
    private var lastInjectedSafeAreaTop: CGFloat = -1

    // MARK: - 开关

    func configure(ignoreTLSErrors: Bool, autoRetry: Bool) {
        self.ignoreTLSErrors = ignoreTLSErrors
        self.autoRetryEnabled = autoRetry
    }

    // MARK: - 生命周期

    /// SwiftUI 第一次创建 WKWebView 时调用（幂等）。
    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView

        observations.forEach { $0.invalidate() }
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                DispatchQueue.main.async { self?.progress = value }
            }
        ]

        if let pending = pendingTarget {
            pendingTarget = nil
            load(pending.base, token: pending.token)
        }
    }

    /// 每次 SwiftUI 刷新都会走到这里，同时用来同步安全区。
    func update(webView: WKWebView) {
        attach(webView)
        syncSafeAreaToPage(webView, force: false)
    }

    // MARK: - 加载

    func load(_ base: URL, token: String) {
        let target = ServerTarget(base: base, token: token)
        self.target = target
        cancelRetry(resetAttempts: true)

        guard let webView else {
            // WebView 还没创建好，等 attach 时再加载。
            pendingTarget = target
            phase = .loading
            return
        }
        start(target, on: webView)
    }

    /// 重新加载当前页面。
    func reload() {
        cancelRetry(resetAttempts: true)
        guard let webView else { return }
        if webView.url == nil, let target {
            start(target, on: webView)
        } else {
            phase = .loading
            webView.reload()
        }
    }

    /// 用户点「重试」：重新走一遍当前目标地址。
    func retry() {
        cancelRetry(resetAttempts: true)
        guard let webView, let target else { return }
        start(target, on: webView)
    }

    /// 从后台回到前台：如果上次是失败状态，立刻重连一次。
    func applicationDidBecomeActive() {
        guard phase.failureMessage != nil, let target, let webView else { return }
        cancelRetry(resetAttempts: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.phase.failureMessage != nil else { return }
            self.start(target, on: webView)
        }
    }

    /// 界面直接给出一个失败原因（例如地址格式不对）。
    func fail(message: String) {
        onMain {
            self.phase = .failed(message)
            self.scheduleRetry()
        }
    }

    /// 清空 Cookie / localStorage / 缓存。
    static func clearWebData(completion: (() -> Void)? = nil) {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            DispatchQueue.main.async { completion?() }
        }
    }

    private func start(_ target: ServerTarget, on webView: WKWebView) {
        progress = 0
        phase = .loading
        var request = URLRequest(url: target.loadURL)
        request.timeoutInterval = 30
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    // MARK: - 自动重试

    private func scheduleRetry() {
        guard autoRetryEnabled, retryAttempt < Self.maxAutoRetry else { return }
        retryAttempt += 1
        // 2 / 4 / 8 秒退火
        retryCountdown = min(8, Int(pow(2.0, Double(retryAttempt))))

        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.retryCountdown -= 1
            guard self.retryCountdown <= 0 else { return }
            timer.invalidate()
            self.retryTimer = nil
            self.retryCountdown = 0
            if let webView = self.webView, let target = self.target {
                self.start(target, on: webView)
            }
        }
    }

    private func cancelRetry(resetAttempts: Bool = false) {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCountdown = 0
        if resetAttempts { retryAttempt = 0 }
    }

    // MARK: - 工具

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// 把真实的顶部安全区写进页面。
    ///
    /// 页面顶栏用 `--dsr-safe-top: max(env(safe-area-inset-top), var(--native-top))` 定位，
    /// 这里补上 `--native-top` 兜底，避免个别情况下 env() 返回 0 导致顶栏压到状态栏下面。
    private func syncSafeAreaToPage(_ webView: WKWebView, force: Bool) {
        let top = (webView.safeAreaInsets.top).rounded()
        guard webView.url != nil, force || top != lastInjectedSafeAreaTop else { return }
        lastInjectedSafeAreaTop = top
        let script = "document.documentElement.style.setProperty('--native-top','\(Int(top))px');"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewModel: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        onMain { self.phase = .loading }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncSafeAreaToPage(webView, force: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncSafeAreaToPage(webView, force: true)
        onMain {
            self.progress = 1
            self.phase = .ready
            self.cancelRetry(resetAttempts: true)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onMain {
            self.phase = .failed("页面渲染进程被系统回收，正在自动恢复…")
            self.scheduleRetry()
        }
    }

    /// 忽略 TLS 证书错误的核心实现：无条件接受服务器出示的证书。
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard ignoreTLSErrors,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func handle(_ error: Error) {
        let nsError = error as NSError
        // 主动发起新导航会取消旧导航，这种「失败」不是错误。
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }

        let message = WebLoadError.message(for: error, ignoreTLSErrors: ignoreTLSErrors)
        guard !message.isEmpty else { return }

        onMain {
            self.phase = .failed(message)
            self.scheduleRetry()
        }
    }
}

// MARK: - WKUIDelegate

extension WebViewModel: WKUIDelegate {

    /// 页面里的 target=_blank / window.open：站内链接就地打开，其它交给系统。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            webView.load(navigationAction.request)
        } else if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        return nil
    }

    /// 页面里的 `alert()`。
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        presentDialog(
            message: message,
            inputDefault: nil,
            confirmTitle: "好",
            cancelTitle: nil,
            completion: { _, _ in completionHandler() },
            fallback: { completionHandler() }
        )
    }

    /// 页面里的 `confirm()`。
    ///
    /// 必须实现：DSH Remote 网页端用 confirm 确认删除分组、中断子代理、停止会话、覆盖文件等操作，
    /// 不实现的话 WebKit 会静默返回 false，这些按钮看起来「点了没反应」。
    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        presentDialog(
            message: message,
            inputDefault: nil,
            confirmTitle: "确定",
            cancelTitle: "取消",
            completion: { confirmed, _ in completionHandler(confirmed) },
            fallback: { completionHandler(false) }
        )
    }

    /// 页面里的 `prompt()`。
    func webView(
        _ webView: WKWebView,
        runJavaScriptPromptWithMessage message: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        presentDialog(
            message: message,
            inputDefault: defaultText,
            confirmTitle: "确定",
            cancelTitle: "取消",
            completion: { confirmed, text in completionHandler(confirmed ? (text ?? "") : nil) },
            fallback: { completionHandler(nil) }
        )
    }

    /// 摄像头/麦克风授权：网页里的扫码和语音输入需要。
    /// 系统级权限仍会照常弹窗（见 Info.plist 的用途说明）。
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    private func presentDialog(
        message: String,
        inputDefault: String?,
        confirmTitle: String,
        cancelTitle: String?,
        completion: @escaping (Bool, String?) -> Void,
        fallback: @escaping () -> Void
    ) {
        onMain {
            guard let presenter = Self.topViewController() else {
                fallback()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            if let inputDefault {
                alert.addTextField { field in
                    field.text = inputDefault
                    field.autocapitalizationType = .none
                    field.autocorrectionType = .no
                }
            }
            if let cancelTitle {
                alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
                    completion(false, nil)
                })
            }
            alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { _ in
                completion(true, alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
