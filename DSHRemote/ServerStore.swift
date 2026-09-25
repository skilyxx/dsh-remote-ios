import Foundation

/// 服务器配置的持久化存储（UserDefaults）。
///
/// 这是「服务器 URL 可配记忆」的唯一数据源：地址、令牌、两个开关都会在改动后立即落盘，
/// 所以 App 被杀掉再打开也会回到同一个服务器。
final class ServerStore: ObservableObject {

    private enum Key {
        static let serverURL = "dsh.serverURL"
        static let token = "dsh.accessToken"
        static let ignoreTLS = "dsh.ignoreTLSErrors"
        static let autoRetry = "dsh.autoRetry"
    }

    private let defaults: UserDefaults

    /// 用户填写的服务器地址，例如 `http://192.168.1.89:8787`。
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL) }
    }

    /// 网关令牌，对应 DSH 主机上的 `~/.dsh-remote/token`；留空表示不带令牌。
    @Published var token: String {
        didSet { defaults.set(token, forKey: Key.token) }
    }

    /// 忽略 TLS 证书错误（自签名证书必需），默认打开。
    @Published var ignoreTLSErrors: Bool {
        didSet { defaults.set(ignoreTLSErrors, forKey: Key.ignoreTLS) }
    }

    /// 连接失败时自动重试（2s / 4s / 8s，最多 3 次），默认打开。
    @Published var autoRetry: Bool {
        didSet { defaults.set(autoRetry, forKey: Key.autoRetry) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURL = defaults.string(forKey: Key.serverURL) ?? ""
        self.token = defaults.string(forKey: Key.token) ?? ""
        self.ignoreTLSErrors = defaults.object(forKey: Key.ignoreTLS) as? Bool ?? true
        self.autoRetry = defaults.object(forKey: Key.autoRetry) as? Bool ?? true
    }

    /// 是否已经配置过服务器地址。
    var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 规范化后的令牌（去掉首尾空白）。
    var normalizedToken: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
