# DSH Remote（iOS）

一个自用的 iOS 壳：全屏 WebView 打开你自建的 DSH Remote 网关，**记住服务器地址**、**忽略 TLS 证书错误**、连不上时**自动重连并给出可排查的提示**。

图标沿用 DSH 自己的鲸鱼图标（由 `/opt/DSH Desktop/resources/icon.png` 生成全套尺寸）。

- 最低系统：iOS 16.0
- 依赖：无（纯 SwiftUI + WebKit，没有第三方库）
- 特殊 entitlement：无（免费 Apple ID 也能签名侧载）

---

## 1. 它到底打开什么

它打开的是 **dsh-remote-plugin 内置网关托管的手机端 WebUI**，默认地址：

```
http://<电脑局域网IP>:8787
```

在电脑上先确认网关是活的：

```bash
curl -i http://127.0.0.1:8787/health     # 应返回 JSON
ss -ltnp | grep ':8787'                  # 应监听 0.0.0.0:8787

cat ~/.dsh-remote/token                  # 访问令牌（等同远程操作凭证，别外泄）
```

几个相关地址：

| 用途 | 地址 |
| --- | --- |
| 手机端 WebUI（App 打开的就是它） | `http://<IP>:8787/` |
| 管理页（配对二维码在这里） | `http://<IP>:8787/admin` |
| 桌面端 WebUI | `http://<IP>:8787/desktop/desktop.html` |

> 网关配置见 `dsh-remote-plugin` 的 README：端口优先级 `DSH_REMOTE_GATEWAY_PORT` → `~/.dsh-remote/gateway-port` → `8787`。
> 手机上的 `127.0.0.1` / `localhost` 指的是手机自己，**必须填电脑的局域网 IP 或 Tailscale IP**。

---

## 2. 构建（没有 Mac 也能做）

本机是 Linux，编译交给 GitHub Actions 的 macOS runner。工作流已经写好：`.github/workflows/build-ipa.yml`。

```bash
cd dsh-remote-ios
git init && git add -A && git commit -m "DSH Remote iOS"

# 用 gh 直接建私有仓库并推送（没有 gh 就手动建仓库后 git remote add）
gh repo create dsh-remote-ios --private --source=. --push
```

然后：

1. 打开仓库 → **Actions** → 左侧 **Build unsigned IPA** → **Run workflow**；
2. 等 2~4 分钟，进这次运行页面，在底部 **Artifacts** 下载 `DSHRemote-unsigned-ipa`；
3. 解压得到 **`DSHRemote.ipa`**。

也可以打 tag 触发：`git tag v1.0.0 && git push --tags`。

工作流做的事就是 `scripts/build-ipa.sh`：`xcodebuild` 关掉签名编译 `Release`，再把 `.app` 塞进 `Payload/` 压成 IPA。如果仓库里的 `.xcodeproj` 有意外，它会自动 `brew install xcodegen && xcodegen generate` 用 `project.yml` 重新生成一份，保证还是能出包。

---

## 3. 装到 iPhone 上（侧载）

IPA 是**未签名**的，需要用自己的 Apple ID 重新签名。三种常见做法：

| 工具 | 需要 | 说明 |
| --- | --- | --- |
| **Sideloadly** | Windows/macOS + 数据线 + Apple ID | 最简单：把 `DSHRemote.ipa` 拖进去，填 Apple ID，Start |
| **AltStore / SideStore** | AltServer（电脑）或配对文件 | 能自动续签，省得每周手动重装 |
| **Xcode**（有 Mac 时） | Mac + Xcode | 直接打开 `DSHRemote.xcodeproj`，选自己的 Team，Run |

装完后第一次打开会提示「不受信任的开发者」，去 **设置 → 通用 → VPN与设备管理** 里信任自己的证书。

⚠️ 用**免费 Apple ID** 签名，证书 **7 天过期**，过期后 App 打不开，需要重新侧载（SideStore/AltStore 可自动续签）。想省事就上 99 美元/年的开发者账号（有效期 1 年）。

---

## 4. 首次使用

### 方式 A：扫码配对（推荐）

1. 电脑浏览器打开 `http://<IP>:8787/admin`，点「配对 / 显示二维码」；
2. 用 **iPhone 相机**直接扫这个二维码（不要用浏览器扫）；
3. 二维码内容是 `dshremote://pair?token=...&server=...`，系统会唤起本 App，**地址和令牌自动填好并连接**。

App 已在 `Info.plist` 注册 `dshremote` URL scheme 来接这个深链。二维码里可能带多个 `server`（局域网 IP、Tailscale 等），App 取第一个。

### 方式 B：手填

点右下角齿轮 → 填地址 → 「测试连接」确认通了 → 「保存并连接」。

- 地址写 `http://192.168.1.89:8787`；
- 只写 `192.168.1.89:8787` 也行，App 会**先试 https 再试 http**，把探到的结果补全并记住；
- 令牌填 `~/.dsh-remote/token` 的内容（也可以先留空，网页端里再填）。

首次连接 iOS 会弹「**允许访问本地网络**」，必须允许，否则连不上局域网。

---

## 5. 功能与实现要点

| 需求 | 实现位置 |
| --- | --- |
| 打开配置的地址 | `WebView.swift`（全屏 WKWebView） |
| 服务器 URL 可配 + 记忆 | `ServerStore.swift`（UserDefaults 落盘）、`SettingsView.swift` |
| 忽略 TLS 证书错误 | `WebViewModel.swift` 的 `didReceive challenge`：`URLCredential(trust:)` 直接放行；探测用的 `URLSession` 在 `ConnectionProbe.swift` 里同样放行 |
| 启动自动重连 + 失败提示 | 2s / 4s / 8s 退火重试（最多 3 次），回到前台且上次失败时立刻重连；失败界面显示中文原因 + 重试/设置 |
| 全屏 + 设置页 | 悬浮齿轮按钮（可拖动、位置记忆），加载时变成进度环 |

顺带补齐了三个「不写就一定出问题」的地方：

1. **`confirm()` 对话框**。DSH 网页端用 `confirm()` 确认删除分组、中断子代理、停止会话、覆盖文件等操作。**不实现 `WKUIDelegate` 的 JS 对话框，WebKit 会静默返回 `false`，这些按钮点了没反应**。现已实现 alert / confirm / prompt。
2. **顶部安全区**。网页用 `--dsr-safe-top: max(env(safe-area-inset-top), var(--native-top))` 定位顶栏。App 除了让 WebView 全屏（`contentInsetAdjustmentBehavior = .never`），还会把真实的安全区写进页面的 `--native-top` 兜底，避免刘海/状态栏压住顶栏。
3. **`target=_blank` 与摄像头授权**。站外链接交给系统浏览器打开；`getUserMedia` 授权直接放行（网页端扫码/语音输入要用），系统级权限照常弹窗。

另外：ATS 已放开（`NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking`），所以 http 和自签名 https 都能连。

---

## 6. 已知限制

- **语音输入 / 网页内扫码需要 HTTPS**。浏览器只在「安全上下文」下提供 `getUserMedia`，`http://192.168.x.x` 不是安全上下文，网页端这两个功能会不可用（网页自己会优雅降级）。想用就给网关套一层 HTTPS（Tailscale serve、Caddy、nginx 都行），本 App 可以忽略自签证书。
- **冷启动扫码**没问题（相机 App 唤起走 URL scheme），不需要摄像头权限的网页代码。
- **未签名 IPA 装出来的 App 没有推送权限**；免费账号 7 天过期。
- 如果以后官方出了 iOS 版 DSH Remote，两边都会注册 `dshremote://`，iOS 只会认一个。
- 令牌存在 UserDefaults 里（不是 Keychain）。自用够，但别把这个 App 分享给别人的设备。
- **本机没有 macOS / Xcode，所以代码只做了静态校验**（见第 8 节），真正的编译验证在 GitHub Actions 第一次跑的时候。

---

## 7. 常见问题

| 现象 | 处理 |
| --- | --- |
| 一直「连不上」 | 电脑上 `curl -i http://127.0.0.1:8787/health`；再用手机浏览器直接开 `http://<IP>:8787` 对比。检查防火墙放行 8787 入站 |
| 手机浏览器能开、App 不行 | 看是不是点了「不允许访问本地网络」：设置 → 通用 → 传输或还原 → 还原 → 还原位置与隐私（会重置权限），再重连 |
| 页面提示 401 | 令牌不对。重扫码，或 `cat ~/.dsh-remote/token` 后手填 |
| TLS 报错 | 设置里打开「忽略 TLS 证书错误」（默认已开） |
| 顶部被状态栏压住 | 网页版本太旧。`--native-top` 兜底需要新版 CSS（`theme-vars.css` 里的 `--dsr-safe-top`） |
| 白屏 | 网页端 Ctrl+F5 强刷过吗？App 里设置 → 清除网页数据与令牌，然后重新填 |
| 想换服务器 | 齿轮 → 改地址 → 保存并连接；或再扫一次配对二维码 |
| 7 天后打不开 | 免费证书过期，重新侧载；或改用 SideStore/AltStore 自动续签 |

---

## 8. 目录结构与本机做过的校验

```
dsh-remote-ios/
├── DSHRemote/
│   ├── DSHRemoteApp.swift      # @main
│   ├── RootView.swift          # 全屏 WebView + 悬浮齿轮 + 失败页 + 首次使用页
│   ├── SettingsView.swift      # 设置页
│   ├── WebView.swift           # WKWebView 封装
│   ├── WebViewModel.swift      # 状态机 / TLS 例外 / 重试 / JS 对话框 / 安全区注入
│   ├── ServerStore.swift       # 地址与开关的持久化
│   ├── ServerAddress.swift     # 地址规范化 + http/https 候选
│   ├── ConnectionProbe.swift   # 可达性探测（忽略证书的 URLSession）
│   ├── WebLoadError.swift      # 错误信息中文化
│   ├── Info.plist              # ATS / 局域网 / 相机 / dshremote:// scheme
│   └── Assets.xcassets/        # AppIcon 全套尺寸 + DSHLogo + 启动背景色
├── DSHRemote.xcodeproj/        # 手写工程（含共享 scheme）
├── project.yml                 # XcodeGen 备用描述
├── scripts/build-ipa.sh        # 本地/CI 出未签名 IPA
├── .github/workflows/build-ipa.yml
└── icons/icon-1024.png         # 图标母版（1024，满幅不透明）
```

本机（Linux，无 Xcode）已完成的校验：

- `project.pbxproj` 用 `xcode` 解析器完整解出：target、3 个 build phase、9 个源文件、Assets 资源、4 份 build configuration，文件引用无缺失；
- 9 个 Swift 文件用 `tree-sitter-swift` 解析，**无 ERROR / MISSING 节点**（语法正确）；
- 所有 `Contents.json` JSON 合法、图标文件名与磁盘一致、无透明度；
- `Info.plist` 用 plistlib 解析通过；`build-ipa.sh` 通过 `bash -n`；两个 YAML 解析通过。

**没做的**：类型检查与真机运行（需要 Xcode）。第一次 Actions 运行如果报编译错误，把日志贴给我即可。

---

## 9. 想改点什么

| 想改 | 改哪 |
| --- | --- |
| App 显示名 | `DSHRemote/Info.plist` 的 `CFBundleDisplayName` |
| Bundle ID | `project.pbxproj` 里两处 `PRODUCT_BUNDLE_IDENTIFIER`（或 `project.yml`） |
| 图标 | 替换 `DSHRemote/Assets.xcassets/AppIcon.appiconset/` 里的 png（母版 `icons/icon-1024.png`，1024×1024、不透明、满幅） |
| 版本号 | `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| 最低系统 | `IPHONEOS_DEPLOYMENT_TARGET`（现为 16.0） |
| 自动重试次数/间隔 | `WebViewModel.maxAutoRetry` 与 `scheduleRetry()` |
| 默认齿轮位置 | `RootView` 里 `@AppStorage("dsh.floatingButtonX"/"Y")` 的初值 |
