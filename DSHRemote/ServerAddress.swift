import Foundation

/// 一次连接所需的完整信息。
struct ServerTarget: Equatable {
    /// 规范化后的基地址，例如 `https://192.168.1.89:8787`。
    let base: URL
    /// 网关令牌，空字符串表示不追加。
    let token: String

    /// 真正加载的地址。
    ///
    /// 令牌通过 `?token=` 传给 WebUI —— DSH Remote 的网页端会读走它写进 localStorage，
    /// 然后 `history.replaceState` 把 token 从地址栏抹掉，所以每次带上是幂等且安全的。
    var loadURL: URL {
        guard !token.isEmpty else { return base }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? base
    }
}

/// 服务器地址的解析与规范化。
enum ServerAddress {

    /// 把用户输入整理成候选地址列表。
    ///
    /// - 已经带 `http://` / `https://`：只有一个候选，原样使用；
    /// - 只写了 `主机:端口`：先试 https，再退回 http，由 `resolve(_:ignoreTLSErrors:)` 探测。
    static func candidates(for raw: String) -> [URL] {
        let text = sanitize(raw)
        guard !text.isEmpty else { return [] }

        if let schemeRange = text.range(of: "://") {
            let scheme = text[text.startIndex..<schemeRange.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return [] }
            return [normalize(text)].compactMap { $0 }
        }

        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard !host.isEmpty else { return [] }
        return [normalize("https://" + text), normalize("http://" + text)].compactMap { $0 }
    }

    /// 探测出真正可用的基地址。
    ///
    /// 只在用户没写协议前缀、存在多个候选时才发起探测；探测全部失败时仍然返回第一个候选，
    /// 让 WebView 去报具体错误。
    static func resolve(_ raw: String, ignoreTLSErrors: Bool) async -> URL? {
        let list = candidates(for: raw)
        guard let first = list.first else { return nil }
        if list.count == 1 { return first }

        for candidate in list {
            if await ConnectionProbe.isReachable(candidate, ignoreTLSErrors: ignoreTLSErrors) {
                return candidate
            }
        }
        return first
    }

    /// 去掉查询串与 fragment（令牌由 App 自己拼），补上默认路径，并校验 host 合法。
    private static func normalize(_ text: String) -> URL? {
        guard var components = URLComponents(string: text) else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// 清理粘贴带进来的零宽字符等不可见字符。
    private static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for invisible in ["\u{200B}", "\u{200E}", "\u{200F}", "\u{FEFF}", "\u{00A0}"] {
            text = text.replacingOccurrences(of: invisible, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 配对链接不是服务器地址，交给 RootView 的深链处理。
        if text.lowercased().hasPrefix("dshremote://") { return "" }
        return text
    }
}
