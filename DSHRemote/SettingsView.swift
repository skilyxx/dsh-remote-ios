import SwiftUI
import UIKit

/// 设置页：服务器地址、令牌、TLS 例外、自动重试，以及维护操作。
struct SettingsView: View {

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    /// 点「保存并连接」后的回调（由 RootView 触发重新加载）。
    let onSave: () -> Void

    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var ignoreTLS = true
    @State private var autoRetry = true
    @State private var testState: TestState = .idle
    @State private var notice: String?
    @State private var didLoad = false

    private enum TestState: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                connectionSection
                pairSection
                maintenanceSection
                aboutSection
            }
            .navigationTitle("DSH Remote 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并连接") { save() }
                        .fontWeight(.semibold)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear(perform: loadFromStore)
    }

    // MARK: - 分区

    private var serverSection: some View {
        Section {
            TextField("http://192.168.1.89:8787", text: $urlText)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .font(.body.monospaced())

            TextField("访问令牌（可留空）", text: $tokenText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            Button {
                pasteFromClipboard()
            } label: {
                Label("从剪贴板填入", systemImage: "doc.on.clipboard")
            }

            Button {
                runTest()
            } label: {
                Label("测试连接", systemImage: "bolt.horizontal")
            }

            testResultRow

            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DSHTheme.accent)
            }
        } header: {
            Text("服务器")
        } footer: {
            Text("填 DSH Remote 网关地址，默认端口 8787，例如 http://192.168.1.89:8787。\n只写「主机:端口」也可以，App 会自动试 https 再试 http 并记住结果。\n令牌对应 DSH 主机上的 ~/.dsh-remote/token，扫码配对后可自动填入。")
        }
    }

    private var connectionSection: some View {
        Section {
            Toggle(isOn: $ignoreTLS) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("忽略 TLS 证书错误")
                    Text("自签名证书必需")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: $autoRetry) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接失败自动重试")
                    Text("2 秒 / 4 秒 / 8 秒，最多 3 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("连接")
        } footer: {
            Text("关掉证书例外后，只有受信任的证书才能连上；遇到自签名证书会直接报错。")
        }
    }

    private var pairSection: some View {
        Section {
            Text("用 iPhone 相机直接扫网关「配对」里的二维码，系统会打开本 App 并自动填入地址和令牌。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("配对")
        }
    }

    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                WebViewModel.clearWebData()
                store.token = ""
                tokenText = ""
                notice = "已清除网页数据与令牌"
            } label: {
                Label("清除网页数据与令牌", systemImage: "trash")
            }

            Button(role: .destructive) {
                store.serverURL = ""
                store.token = ""
                urlText = ""
                tokenText = ""
                notice = "已清空服务器配置"
            } label: {
                Label("清空服务器配置", systemImage: "xmark.circle")
            }
        } header: {
            Text("维护")
        } footer: {
            Text("清除网页数据会一并清掉网页端保存的服务器列表与登录状态，之后需要重新填令牌。")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(versionText).foregroundStyle(.secondary)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("DSH Remote iOS · 全屏 WebView 壳，只做地址记忆与证书例外。")
        }
    }

    @ViewBuilder
    private var testResultRow: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                Text("正在连接…").foregroundStyle(.secondary)
            }
        case .ok(let url):
            Label("连接成功：\(url)", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - 行为

    private func loadFromStore() {
        guard !didLoad else { return }
        didLoad = true
        urlText = store.serverURL
        tokenText = store.token
        ignoreTLS = store.ignoreTLSErrors
        autoRetry = store.autoRetry
    }

    private func save() {
        store.serverURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.ignoreTLSErrors = ignoreTLS
        store.autoRetry = autoRetry
        onSave()
        dismiss()
    }

    private func runTest() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            testState = .failed("请先填写服务器地址")
            return
        }
        testState = .testing
        let allowsInsecureTLS = ignoreTLS

        Task {
            let resolved = await ServerAddress.resolve(raw, ignoreTLSErrors: allowsInsecureTLS)
            guard let resolved else {
                await MainActor.run { testState = .failed("地址格式无法解析") }
                return
            }
            let reachable = await ConnectionProbe.isReachable(resolved, ignoreTLSErrors: allowsInsecureTLS, timeout: 6)
            await MainActor.run {
                testState = reachable
                    ? .ok(resolved.absoluteString)
                    : .failed("连不上 \(resolved.absoluteString)")
            }
        }
    }

    /// 支持粘贴普通地址，或配对链接 `dshremote://pair?token=..&server=..`。
    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            notice = "剪贴板是空的"
            return
        }

        if raw.lowercased().hasPrefix("dshremote://") {
            let items = URLComponents(string: raw)?.queryItems ?? []
            guard let server = items.first(where: { $0.name == "server" })?.value, !server.isEmpty else {
                notice = "配对链接里没有 server 参数"
                return
            }
            urlText = server
            if let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty {
                tokenText = token
            }
            notice = "已从配对链接填入地址和令牌"
            return
        }

        if let components = URLComponents(string: raw),
           let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
           !token.isEmpty {
            tokenText = token
            urlText = ServerAddress.candidates(for: raw).first?.absoluteString ?? raw
            notice = "已填入地址和令牌"
            return
        }

        urlText = raw
        notice = "已填入地址"
    }
}
