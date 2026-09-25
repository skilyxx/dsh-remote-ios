import SwiftUI
import WebKit

/// 全屏 WKWebView。
///
/// 页面用 `viewport-fit=cover` 并自己处理安全区（`--dsr-safe-top`），所以这里：
/// - 让 WebView 铺满整屏（外层 `.ignoresSafeArea()`）；
/// - `contentInsetAdjustmentBehavior = .never`，由页面自己留白，避免双重内边距。
struct WebView: UIViewRepresentable {

    @ObservedObject var model: WebViewModel

    /// 深色底，避免加载瞬间白闪。
    private let backgroundColor = UIColor(red: 13 / 255, green: 17 / 255, blue: 23 / 255, alpha: 1)

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // iOS 15.4+：允许页面元素进入全屏（会话详情里的全屏输入等）。
        configuration.preferences.isElementFullscreenEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = model
        webView.uiDelegate = model
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor

        if #available(iOS 16.4, *) {
            // 方便用 Safari 远程调试（自用 App，开着更省事）。
            webView.isInspectable = true
        }

        model.attach(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        model.update(webView: webView)
    }
}
