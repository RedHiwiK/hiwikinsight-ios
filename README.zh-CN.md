# HiwiKInsightKit

[English](README.md) | 简体中文

一个轻量、零依赖、隐私优先的 iOS 埋点 SDK。它记录匿名使用事件，压缩后批量发送到你自己部署的
[HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight) 服务端。

- 零第三方依赖，Swift 6，iOS 17+
- 自动采集安装 / 升级 / 会话 / 页面
- 启动来源与内购归因
- 磁盘队列：崩溃、离线都不丢事件

上报协议见 [PROTOCOL.md](PROTOCOL.md)（英文），它是 SDK 与服务端之间唯一的约定。

## 隐私

- **匿名安装 ID**：每次安装生成一个随机 UUID，存在 `UserDefaults` 中。它不来自任何设备标识，
  既不是 IDFA 也不是 IDFV，卸载重装后会变。
- **不采集个人信息**：SDK 不采集姓名、邮箱、手机号、通讯录、位置或广告标识。自定义参数请只传
  桶化、不可识别个人的值（例如 `"entry_count": "10-50"`，而不是精确数值或自由文本）。
- **不采集 IP**：SDK 不采集 IP 地址，HiwiKInsight 的接收端也不会把 IP 与事件一起存储。
- **不跨 App 追踪**：数据只发往你配置的服务端。
- `HiwiKInsight.setEnabled(false)` 停止采集并删除所有未发送的事件，可用于实现 App 内的「关闭统计」开关。

## 安装

Swift Package Manager：

```swift
dependencies: [
    .package(url: "https://github.com/RedHiwiK/hiwikinsight-ios", from: "0.2.0"),
]
```

或在 Xcode 中：**File > Add Package Dependencies...**，输入
`https://github.com/RedHiwiK/hiwikinsight-ios`。

## 快速开始

```swift
import HiwiKInsightKit

// 1. App 启动时调用一次（例如在 App 的 init 中）
HiwiKInsight.start(.init(appKey: "pawprint", endpoint: URL(string: "https://insight.example.com")!)) {
    // 可选的用户快照，每天首次会话上报一次。请使用桶化值
    ["entry_count": "10-50", "is_pro": "true"]
}

// 2. 自定义事件
HiwiKInsight.signal("entry.created", ["entry_type": "note"])

// 3. 错误
HiwiKInsight.error(id: "sync.failed", category: "thrown-exception", message: "timeout")

// 4. 页面（SwiftUI）：出现时记 screen.viewed，消失时记 screen.left 及停留时长
SettingsView().trackScreen("settings", module: "settings")

// 5. 启动来源：被小组件、通知、快捷指令等拉起时调用
HiwiKInsight.setLaunchSource("widget_today")

// 6. 购买归因：返回的 UUID 通过 StoreKit 的 appAccountToken 与 App Store 服务器通知，
//    把这笔购买关联到当前入口
let token = HiwiKInsight.beginPurchase(product: product.id, context: "paywall_onboarding")
let result = try await product.purchase(options: [.appAccountToken(token)])
```

`trackScreen` 只挂在独立页面上（push / fullScreenCover / sheet 的根视图）。常驻挂载的 Tab 根视图，
请在切换 Tab 的地方手动调用 `HiwiKInsight.screenViewed(_:module:)`。

### 自动采集

- `app.installed`、`app.acquired`、`app.updated`
- `session.started` / `session.ended`（在后台超过 5 分钟再回来算新会话）
- 批次公共属性：App 版本与 build、系统与版本、机型、locale、语言、地区、App Store 国家、
  环境（`production` / `sandbox` / `xcode`）、外观、动态字体档位

所有内置事件及参数见 [PROTOCOL.md](PROTOCOL.md#built-in-sdk-events)。

## 配置

`HiwiKInsightConfiguration` 的属性（除 `appKey` 与 `endpoint` 外都有默认值）：

| 属性 | 默认值 | 说明 |
|---|---|---|
| `appKey` | （必填） | App 标识，必须在服务端白名单中 |
| `endpoint` | （必填） | 服务端基础地址，事件发往 `<endpoint>/v1/events` |
| `defaultsSuiteName` | `nil` | 存放安装 ID 与会话状态的 UserDefaults suite（`nil` 即 `.standard`） |
| `sessionTimeout` | `300` 秒 | 在后台超过该时长再回来算新会话 |
| `flushInterval` | `30` 秒 | 定时发送间隔 |
| `flushThreshold` | `50` | 队列攒够多少条立即发送 |
| `maxQueuedEvents` | `2000` | 队列上限，超出丢弃最旧的 |
| `launchSourceWindow` | `1.5` 秒 | `session.started` 等待 `setLaunchSource` 的时长 |
| `hasPriorUsage` | `false` | App 判断本机在接入 SDK 之前已用过时设为 `true`，随 `app.installed` 上报 `prior_usage=1` |
| `debugLogging` | `false` | 通过 `os.Logger` 打印每条事件 |

```swift
var config = HiwiKInsightConfiguration(appKey: "pawprint", endpoint: URL(string: "https://insight.example.com")!)
config.hasPriorUsage = LocalStore.hasExistingData
config.debugLogging = true
HiwiKInsight.start(config)
```

## 批量发送与离线

- 事件先追加写入 `Application Support/HiwikInsight/<appKey>/queue.jsonl`，崩溃或进程被杀都不丢；
  队列上限 2000 条（超出丢弃最旧的）。
- 满 50 条、每 30 秒、进入后台时批量发送（每批最多 200 条），请求体使用 raw DEFLATE 压缩。
- `5xx`、`408`、`429` 和网络错误会保留这批并退避重试（30 秒、2 分钟、10 分钟、1 小时）；
  其余 `4xx` 丢弃这批，避免坏数据卡住队列。
- Release 包在本机从未拿到过 `AppTransaction` 时，会先暂停发送直到确定环境，避免 TestFlight 数据混入正式数据。
- `await HiwiKInsight.flush()` 立即发送队列。

## 环境要求

- iOS 17+（包也可在 macOS 14+ 上编译，便于在 Mac 上跑测试）
- Swift 6 工具链（Xcode 16+）

## 服务端

HiwiKInsightKit 对接自部署的接收与看板服务 [HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight)。
注册 `appKey`、部署服务端请参考它的
[SDK 接入指南](https://github.com/RedHiwiK/HiwiKInsight/blob/main/docs/sdk-integration.md)。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
