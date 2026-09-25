import Combine
import SwiftUI
import UIKit

/// 全局配色，跟随 DSH 的深色风格。
enum DSHTheme {
    static let background = Color(red: 13 / 255, green: 17 / 255, blue: 23 / 255)
    static let panel = Color(red: 22 / 255, green: 27 / 255, blue: 34 / 255)
    static let accent = Color(red: 88 / 255, green: 166 / 255, blue: 255 / 255)
    static let warning = Color(red: 240 / 255, green: 180 / 255, blue: 80 / 255)
}

struct RootView: View {

    @EnvironmentObject private var store: ServerStore
    @StateObject private var model = WebViewModel()

    /// 悬浮齿轮的位置（相对屏幕的 0~1 比例），可拖动，会记住。
    @AppStorage("dsh.floatingButtonX") private var buttonX: Double = 0.93
    @AppStorage("dsh.floatingButtonY") private var buttonY: Double = 0.40

    @State private var showSettings = false
    @State private var didBootstrap = false
    @State private var isResolving = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DSHTheme.background

                if store.isConfigured {
                    WebView(model: model)
                        .ignoresSafeArea()
                    overlays(size: proxy.size)
                } else {
                    WelcomeView { showSettings = true }
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsView(onSave: { connect() })
                .environmentObject(store)
        }
        .onAppear(perform: bootstrap)
        .onOpenURL(perform: handlePairLink)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            model.applicationDidBecomeActive()
        }
    }

    @ViewBuilder
    private func overlays(size: CGSize) -> some View {
        if let message = model.phase.failureMessage {
            FailureOverlay(
                message: message,
                url: store.serverURL,
                retryCountdown: model.retryCountdown,
                retryAttempt: model.retryAttempt,
                maxRetry: WebViewModel.maxAutoRetry,
                onRetry: { model.retry() },
                onSettings: { showSettings = true }
            )
        } else {
            FloatingSettingsButton(
                x: $buttonX,
                y: $buttonY,
                container: size,
                isLoading: model.phase.isLoading,
                progress: model.progress,
                action: { showSettings = true }
            )
        }

        if isResolving {
            ResolvingPill()
        }
    }

    // MARK: - 启动与连接

    private func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        model.configure(ignoreTLSErrors: store.ignoreTLSErrors, autoRetry: store.autoRetry)

        if store.isConfigured {
            connect()
        } else {
            showSettings = true
        }
    }

    /// 解析地址（必要时探测 http/https）并加载。
    private func connect() {
        let raw = store.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            model.fail(message: "还没有配置服务器地址。")
            return
        }

        model.configure(ignoreTLSErrors: store.ignoreTLSErrors, autoRetry: store.autoRetry)
        let ignoreTLS = store.ignoreTLSErrors
        isResolving = true

        Task {
            let resolved = await ServerAddress.resolve(raw, ignoreTLSErrors: ignoreTLS)
            await MainActor.run {
                isResolving = false
                guard let resolved else {
                    model.fail(message: "地址无法解析：「\(raw)」\n请填完整地址，例如 http://192.168.1.89:8787")
                    return
                }
                // 记住探测结果：下次就不用再猜协议了。
                if store.serverURL != resolved.absoluteString {
                    store.serverURL = resolved.absoluteString
                }
                model.load(resolved, token: store.normalizedToken)
            }
        }
    }

    /// 处理配对二维码：`dshremote://pair?token=..&server=..`（server 可重复）。
    private func handlePairLink(_ url: URL) {
        guard url.scheme?.lowercased() == "dshremote" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        let token = (items.first { $0.name == "token" }?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let servers = items
            .filter { $0.name == "server" }
            .compactMap { $0.value }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }

        guard let server = servers.first else { return }

        store.serverURL = server
        if !token.isEmpty { store.token = token }
        showSettings = false
        connect()
    }
}

// MARK: - 悬浮设置按钮

/// 全屏网页没有原生入口，用一个半透明可拖动的小齿轮进设置页。
/// 默认贴在右侧偏上，长按拖动可换位置，位置会记住。
private struct FloatingSettingsButton: View {

    @Binding var x: Double
    @Binding var y: Double
    let container: CGSize
    let isLoading: Bool
    let progress: Double
    let action: () -> Void

    @State private var translation: CGSize = .zero
    @State private var dragging = false

    private let diameter: CGFloat = 44

    var body: some View {
        let margin = diameter / 2 + 6
        let maxX = max(margin, container.width - margin)
        let maxY = max(margin, container.height - margin)
        let baseX = x * max(container.width, 1)
        let baseY = y * max(container.height, 1)
        let currentX = min(max(baseX + translation.width, margin), maxX)
        let currentY = min(max(baseY + translation.height, margin), maxY)

        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.5))

            if isLoading {
                Circle()
                    .trim(from: 0, to: max(0.06, min(1, progress)))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(7)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            } else {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .opacity(dragging ? 0.95 : 0.6)
        .contentShape(Circle())
        .position(x: currentX, y: currentY)
        .onTapGesture { action() }
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    dragging = true
                    translation = value.translation
                }
                .onEnded { value in
                    dragging = false
                    translation = .zero
                    x = min(max((baseX + value.translation.width) / max(container.width, 1), 0.03), 0.97)
                    y = min(max((baseY + value.translation.height) / max(container.height, 1), 0.03), 0.97)
                }
        )
        .animation(.easeOut(duration: 0.15), value: dragging)
    }
}

// MARK: - 正在解析地址

private struct ResolvingPill: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("正在解析服务器地址…")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .padding(.bottom, 28)
        }
    }
}

// MARK: - 连接失败

private struct FailureOverlay: View {

    let message: String
    let url: String
    let retryCountdown: Int
    let retryAttempt: Int
    let maxRetry: Int
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack {
            DSHTheme.background.opacity(0.98)

            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(DSHTheme.warning)

                Text("连不上 DSH Remote")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)

                Text(url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(2)
                    .truncationMode(.middle)

                if retryCountdown > 0 {
                    Text("\(retryCountdown) 秒后自动重试（第 \(retryAttempt)/\(maxRetry) 次）")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                HStack(spacing: 12) {
                    Button(action: onRetry) {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(DSHPrimaryButtonStyle())

                    Button(action: onSettings) {
                        Label("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(DSHSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(28)
        }
    }
}

// MARK: - 首次使用

private struct WelcomeView: View {

    let onConfigure: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image("DSHLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text("DSH Remote")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)

            Text("把 DSH Remote 网关地址填进来，就能在 iPhone 上使用完整控制台。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 24)

            Button(action: onConfigure) {
                Label("配置服务器地址", systemImage: "link")
            }
            .buttonStyle(DSHPrimaryButtonStyle())
            .padding(.top, 4)

            Text("例如 http://192.168.1.89:8787\n也可以直接扫网关里的配对二维码，自动填入地址和令牌")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.4))
                .padding(.horizontal, 24)
        }
        .padding(24)
    }
}

// MARK: - 按钮样式

struct DSHPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.7 : 0.95)))
    }
}

struct DSHSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : 0.12)))
    }
}
