import Foundation

/// 把系统错误翻译成能直接照着排查的中文提示。
enum WebLoadError {

    static func message(for error: Error, ignoreTLSErrors: Bool) -> String {
        let nsError = error as NSError

        guard nsError.domain == NSURLErrorDomain else {
            // WebKit 自己的错误（WKErrorDomain）等，直接用系统描述。
            let described = nsError.localizedDescription
            return described.isEmpty ? "加载失败，请重试。" : described
        }

        switch URLError.Code(rawValue: nsError.code) {
        case .cannotFindHost:
            return "无法解析服务器地址。请检查地址拼写，或确认主机名能被手机解析。"
        case .dnsLookupFailed:
            return "DNS 查询失败。若使用主机名，请改用局域网 IP 试试。"
        case .cannotConnectToHost:
            return "无法连接到服务器。请确认端口正确、DSH 网关已启动，且手机和主机在同一网络。"
        case .timedOut:
            return "连接超时。服务器可能未启动，或被防火墙拦住了。"
        case .networkConnectionLost:
            return "网络连接中断，正在等待网络恢复。"
        case .notConnectedToInternet:
            return "手机当前没有网络连接。"
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .secureConnectionFailed,
             .clientCertificateRejected,
             .clientCertificateRequired:
            if ignoreTLSErrors {
                return "TLS 握手失败。已开启忽略证书错误，请确认服务器确实在讲 HTTPS，或改用 http 地址。"
            }
            return "TLS 证书校验失败。如果是自签名证书，请到设置里打开「忽略 TLS 证书错误」。"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统 ATS 拦截了该地址。请改用 https，或检查 App 的 ATS 例外是否生效。"
        case .unsupportedURL:
            return "地址格式不受支持。请写成 http://主机:端口 的形式。"
        case .badURL:
            return "地址格式不正确。"
        case .cancelled:
            return ""
        default:
            let described = nsError.localizedDescription
            return described.isEmpty ? "加载失败，请重试。" : described
        }
    }
}
