import Foundation

/// 地址可达性探测。
///
/// 只在用户没写协议前缀（`192.168.1.89:8787`）时用来决定 http 还是 https，
/// 以及设置页的「测试连接」按钮。
enum ConnectionProbe {

    static func isReachable(_ base: URL, ignoreTLSErrors: Bool, timeout: TimeInterval = 4) async -> Bool {
        var request = URLRequest(url: base)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await InsecureSession.session(ignoreTLSErrors: ignoreTLSErrors).data(for: request)
            // 401 也算通了：网关在，只是没带令牌。
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }
}

/// 可以忽略证书错误的 URLSession。
///
/// WKWebView 的证书例外靠 `WKNavigationDelegate` 处理，但探测走的是 URLSession，
/// 需要同样忽略自签名证书，否则 https 候选永远探测失败。
final class InsecureSession: NSObject, URLSessionDelegate {

    private static var cache: [Bool: InsecureSession] = [:]
    private static let lock = NSLock()

    private let ignoreTLSErrors: Bool

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    static func session(ignoreTLSErrors: Bool) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[ignoreTLSErrors] { return existing.session }
        let created = InsecureSession(ignoreTLSErrors: ignoreTLSErrors)
        cache[ignoreTLSErrors] = created
        return created.session
    }

    private init(ignoreTLSErrors: Bool) {
        self.ignoreTLSErrors = ignoreTLSErrors
        super.init()
    }

    func urlSession(
        _ session: URLSession,
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
}
