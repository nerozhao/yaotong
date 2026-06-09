# 腰痛 - 技术方案

> 本文档描述工程实现：架构、文件结构、关键技术选型、构建测试流程、踩过的坑。
> 产品需求、用户场景、UI 行为定义见 [REQUIREMENTS.md](REQUIREMENTS.md)。

---

## 1. 技术栈

| 维度 | 选择 |
|------|------|
| 平台 | macOS 12+（LSUIElement 菜单栏独占） |
| 语言 | Swift 5.9+ |
| UI | AppKit（NSStatusItem + NSMenu）+ SwiftUI（主界面窗口） |
| 包管理 | Swift Package Manager |
| 配置存储 | `UserDefaults`（`yaotong.workMinutes` / `yaotong.restMinutes`）—— **`isPaused` 是纯内存**，不持久化 |
| 活动检测 | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: ...)`，1 call/tick 基线 |
| 菜单栏图标 | SF Symbol `circle.fill`，18pt，白色 template / 红色 `paletteColors: [.systemRed]` / 蓝色 `paletteColors: [.systemBlue]`，**构造一次缓存复用**；**进入 `.overtime` 时跑一次 0.18s × 5 步的红/空闪烁再稳定** |
| Dock 图标 | `Resources/AppIcon.png`（构建时由 `Resources/generate_icon.swift` 生成）—— 1024×1024 白底圆角矩形 + 蓝色填充圆（80% 直径，10% 内边距）。`Info.plist` 配 `CFBundleIconFile = AppIcon`，macOS 自动 downscale 到各 Dock 尺寸 |
| 日志 | `os_log`，subsystem `local.yaotong`，category `activity`，`.default` 级别；只写状态机事件 |

---

## 2. 架构

```
AppDelegate  ──┬─► ConfigStore (UserDefaults, ObservableObject)
               ├─► StateMachine (pure, lastEvent 输出)
               ├─► ActivityMonitor (CGEventSource 包装)
               ├─► AppState (实时计时, ObservableObject)
               ├─► StatusBarController (NSStatusItem + NSMenu)
               ├─► UpdateChecker (async, GitHub Releases JSON)
               ├─► UpdatePrompt (@MainActor, NSAlert 渲染)
               └─► MainWindowController (NSWindow + NSHostingController)
                       └─► MainView (SwiftUI: 工作/休息计时器 + 设置)
```

1 Hz Timer（tolerance 0.1s）→ `tick()` → `activity.sample()` 拿 idle → `stateMachine.tick()` 返回三态 `StatusState`（`.working` / `.overtime` / `.rested`）→ 推 `appState` → `statusBar.setState()` 切换缓存 icon → `os_log` 写状态机事件。`.working` 和 `.rested` 是单步指针切换；`.overtime` 的入口会启动一个 0.18s × 5 步的红/空闪烁 Timer 再稳定为红色。启动 5s 后另起 `Task` 跑 `UpdateChecker.check(source: .background)`，UI 点击则走 `.manual`。

---

## 3. 文件结构

```
Sources/Yaotong/
├── AppDelegate.swift            NSApplicationDelegate + 1Hz tick + 启动装配
├── ConfigStore.swift            UserDefaults 包装, ObservableObject
├── StateMachine.swift           两个独立计时器 + waitingForActivity 门 + startFreshSession()（用户主动重置，不挂门） + handleSleepWake()（系统休眠唤醒，挂门）
├── ActivityMonitor.swift        CGEventSource 包装, sample() 返回 idle
├── StatusBarController.swift    NSStatusItem + NSMenu + 缓存 SF Symbol
├── AppState.swift               work/rest 时长 + 阈值 (4 个 @Published)
├── MainView.swift               主界面 SwiftUI 视图
├── MainWindowController.swift   NSWindow + NSHostingController, 启动后自动打开
├── UpdateChecker.swift          async 网络检查 + semver 比较 + skippedVersion 持久化
├── UpdatePrompt.swift           @MainActor NSAlert 渲染（结果 + 源 → 弹/不弹）
├── Notifier.swift               UNUserNotificationCenter 包装, 工作/休息事件分发
└── SmokeTest.swift              --smoke-test 模式, 驱动 §6.2 集成测试
Tests/YaotongTests/
├── StateMachineTests.swift      计时器 + 门 + 事件 + 跨阈值
├── ConfigStoreTests.swift       持久化 / 暂停 / 切换
└── UpdateCheckerTests.swift     semver 解析/比较 + shouldShow 决策矩阵 + UserDefaults 往返
Resources/Info.plist             LSUIElement=true, NSPrincipalClass=NSApplication
build.sh                         本地打包脚本
Package.swift                    SwiftPM 清单
```

---

## 4. 关键技术决策

### 4.1 活动信号：CGEventSource 而非全局监听

**结论**：只调用一次 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .any)`，**不安装**任何 `CGEventTap` / `NSEvent monitor`，**不区分**活动类型。

**原因**：
- 不需要申请辅助功能（Accessibility）权限
- 不污染用户的事件流（事件监听有性能影响）
- 一次系统调用，零状态

**判定**：`idleSeconds < 1.0` 即视为"活动"，归零 `restTime`；否则把 `restTime` 设成系统的 `idleSeconds`。状态机只看这个数。

**日志**：只写状态机事件（`工作会话开始` / `休息判定` / `超时判定` / `休眠 gap`）。早期实现区分 12 种活动类型并按 5s 节流写入 `os_log`，但属高频噪音，状态机事件已覆盖用户需要的信息——**已移除**。

在「控制台.app」中按 `subsystem:local.yaotong` 或 `process:Yaotong` 过滤即可看到条目；命令行：

```bash
log show --predicate 'subsystem == "local.yaotong"' --info --last 5m
```

`0xFFFFFFFF` 是 `kCGAnyInputEventType` 的原始值 —— Swift overlay 没有给 `CGEventType.any` 这样的 case，需要手动构造。

### 4.2 图标渲染：paletteColors 烧进 image + 缓存

**坑 1（颜色）**：macOS `NSStatusItem.button.contentTintColor` **不**对 SF Symbol 生效。设了 `isTemplate = false` + `contentTintColor = .systemRed` 后，图标显示的是 SF Symbol 的原始黑色，**不是红色**。

**修复 1**：用 `NSImage.SymbolConfiguration(paletteColors: [.systemRed])` + `withSymbolConfiguration` 把红色烧进 `NSImage` 本身。三种状态用同一个 `makeTintedIcon(_:)` 工厂，仅颜色参数不同（`.systemRed` / `.systemBlue`），`working` 仍是 template 走系统色。

**坑 2（耗电）**：旧实现每 tick 调用 `workingIcon()` / `overtimeIcon()` 工厂方法，里面走一遍 `NSImage(systemSymbolName:)` + `withSymbolConfiguration()` —— 每秒两次 NSImage 分配，每小时 7200 次。状态基本不变，纯粹浪费。

**修复 2**：`StatusBarController` 在 `init` 里 `makeWorkingIcon()` / `makeOvertimeIcon()` / `makeRestedIcon()` 各算一次，存为 `workingImage` / `overtimeImage` / `restedImage` 实例属性；`setState(_:)` 只做一次指针切换。

```swift
private static let iconConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
private let workingImage: NSImage
private let overtimeImage: NSImage
private let restedImage: NSImage

init(...) {
    self.workingImage = StatusBarController.makeWorkingIcon()
    self.overtimeImage = StatusBarController.makeOvertimeIcon()
    self.restedImage = StatusBarController.makeRestedIcon()
}

func setState(_ state: StatusState, animated: Bool = true) {
    // ...
    // .overtime 时若 previous != .overtime 启动闪烁（见下）
}
```

**超时入口的闪烁动画**：仅在状态从"非超时"跨入"超时"那一次触发——`setState` 内部用 `currentState` 记录上一次状态，跨入时调度一个 `Timer(timeInterval: 0.18, repeats: true)`，按 `[red, nil, red, nil, red, nil, red(settle)]` 交替切换 `statusItem.button?.image`；最后一次回调把 `flashTimer` 置空、把 `image` 锁定为红色。同一超时期间的后续 tick 走"长超时"分支（`previous == .overtime`），**不再重新闪烁**。

切换到任何其他状态都会先 `cancelFlash()`，timer 内部再用 `currentState == .overtime && flashTimer === timer` 双保险防止状态中途变化的竞态。`setState(_:animated: false)` 给 smoke test 跳过闪烁直接拿到稳态图像，避免跟 Timer 赛跑。

**测试**：smoke test 读 icon 的 bitmap 像素，对每种颜色分别断言 >30% 的不透明像素 R/B 通道占主导。把 icon 状态直接 dump 到 `/tmp/yaotong-overtime-icon.png` / `/tmp/yaotong-rested-icon.png` / `/tmp/yaotong-working-icon.png` 供视觉验证。

### 4.3 状态机：墙钟工作 + 休息后的活动门

`StateMachine` 持有两个独立计数器 + 一个门：

- **`workTime` = 自上次休息以来的墙钟时长**。每 tick +1，**不依赖**活动。`restTime` 跨过阈值时被重置为 0，并触发"等待活动"门。
- **`restTime` = 自上次活动以来的空闲时长**。活动时归零，空闲时取系统的 `idleSeconds`。
- **`waitingForActivity`**：布尔门。休息判定命中后置 true，期间 `workTime` 保持 0；下一次活动 tick 释放门，工作下一 tick 重新开始累加。

`tick(now:idleSeconds:isPaused:)` 返回 `StatusState`（三态）：
- `overtime`：当 `workTime >= workThreshold`
- `rested`：`waitingForActivity` 门已挂上（休息判定命中、或 `handleSleepWake` 触发）—— 跟"正常工作"区分开，让 UI 显示蓝色
- `working`：其他（工作计时从 0 累加的常态、暂停态、门刚释放那一 tick）

按"刚刚跨过"模式触发事件 `lastEvent: StateMachineEvent`：
- `workSessionStarted` —— `workTime` 从 0 → 1，或"等待活动"门释放后第一 tick
- `workSessionReset(idleSeconds:)` —— `restTime` 跨过休息阈值，重置 `workTime = 0` 并挂起门
- `overtimeReached(elapsed:)` —— `workTime` 跨过工作阈值
- `paused` —— 暂停中
- `.none` —— 常规 tick

按用户要求：工作计时是墙钟（鼠标不动也累加），但休息判定命中后会挂起门直到下一次活动才重新开始。

#### 4.3.1 系统休眠 / 唤醒

`StateMachine.handleSleepWake()` 把"系统睡过了"当成"已充分休息"事件：`workTime = 0`、`restTime = 0`、挂上"等待活动"门、`lastEvent = .workSessionReset(idleSeconds: 0)`。下一次活动 tick 释放门，再下 tick 工作才重新累加。逻辑跟用户离开工位休息 10+ 分钟触发的 reset 完全一致——**长睡 = 长休息**。

#### 4.3.2 用户主动重置（"重置计时器"按钮）

`StateMachine.startFreshSession()` 是用户**在场**时主动宣告"我休息好了，开始工作"的入口——与 `handleSleepWake` 形成对照：

- **不**挂"等待活动"门：用户正在操作菜单/主界面，他们就在电脑前，不需要等下一次输入
- **不**发 `workSessionReset` 事件（`lastEvent = .none`）——避免触发 `Notifier.clearDelivered()` 把超时通知清掉。下一个 tick 自然走 `0 → 1` 路径 emit `workSessionStarted`
- `workTime = 0` + `restTime = 0`——下一个 tick 立刻从 0 开始累加，不存在 `handleSleepWake` 那种"等下一次活动才释放"的延迟

`AppDelegate.manualReset()` 调 `stateMachine.startFreshSession()`，**同步**把 `appState` 两个 `@Published` 写 0、`statusBar.setState(.working)` 取消可能的超时闪烁——避免用户等下一个 1Hz tick 才看到刷新。`os_log` 写一条 `重置计时器：用户主动开始新工作会话`，便于控制台.app 追溯。

**为什么不复用 `handleSleepWake`**：两者的**外可观测行为**（`lastEvent`）不同——`handleSleepWake` emit `workSessionReset` 触发的"清通知"行为对手动重置是错的（用户从未休息够 10 分钟，不应该把超时通知当"已处理"清掉）。命名上也对不上：`handleSleepWake` 字面意思是"系统休眠唤醒"。

`MainView` 的重置按钮在暂停时 `.disabled(!running)`——暂停态下两个计时器本就冻结在 0，重置是空操作，禁掉更明确。

`AppDelegate` 在 `tick()` 里做墙钟 gap 检测：持 `lastTickWallTime: Date?`，每次 tick 算 `gap = now - last`。`gap > 2.0s` → `os_log` + `handleSleepWake()`。阈值取 2s 是因为：1s timer + 0.1s tolerance + 调度抖动 ≤ 1.5s，2s 留出裕度过滤掉正常 jitter。

不再监听 `NSWorkspace.didWakeNotification`——gáp 检测的覆盖面足够（本机不会 hard power event 后还能从休眠恢复到同一进程），省掉一个系统通知的 bridge。

### 4.4 主界面窗口：SwiftUI + AppKit 桥接 + Dock 联动

- `MainWindowController` 用 `NSHostingController` 把 `MainView` 塞进 `NSWindow.contentViewController`
- 启动后 `DispatchQueue.main.async { mainWindow.open() }` 自动弹出
- 窗口位置用 `NSWindow.setFrameAutosaveName("YaotongMainWindow")` 自动持久化（UserDefaults），下次 `open()` 时若返回值 `false`（无存档）才退回 `NSScreen.main.visibleFrame` 手动算中心（避免 `center()` 在多屏下落到屏外）
- `MainView` 用 `@ObservedObject` 绑定 `ConfigStore` 和 `AppState`；Picker 改动通过 ConfigStore 写到 UserDefaults
- 关闭主窗口（点 X）不会退出 App；点"退出 腰痛"按钮调用 `NSApp.terminate(nil)`；点"重启 腰痛"按钮调用 `AppDelegate.restartApp()`

**Dock 图标随窗口状态切换**：`Info.plist` 把默认 `LSUIElement=true`（不显示在 Dock）。`MainWindowController.open()` 里把 activation policy 切到 `.regular`（Dock 显示图标，Cmd-Tab 也能切到）；`NSWindow.willCloseNotification` 监听关窗，切回 `.accessory`（回到纯菜单栏模式）。结果：菜单栏永远在，主窗口打开时 Dock 有图标，关闭后图标消失。

**Dock 图标本身**：构建时由 `Resources/generate_icon.swift` 渲染并写到 `Resources/AppIcon.png`，`build.sh` 拷进 `.app/Contents/Resources/`。`Info.plist` 配 `CFBundleIconFile = AppIcon`，macOS 把它烧成 Dock / Finder / Cmd-Tab 切换器显示的图标。`AppIcon.make()` 同步存在作为运行时兜底（`NSApp.applicationIconImage`），不过对 .app bundle 来说 bundle 自带的 PNG 是主路径。

**为什么用蓝色不用红色**：菜单栏超时图标保留红色（警报语义），Dock 图标是品牌色常驻，红色太刺眼。`systemBlue` 跟"健康提醒"主题更合，也跟 macOS 自身的强调色一致。


**重启流程**：
```swift
func restartApp() {
    let path = Bundle.main.bundlePath
    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.3 && /usr/bin/open -n '\(escaped)'"]
    try? task.run()  // 独立进程，fire-and-forget
    NSApp.terminate(nil)  // 当前进程退出
}
```

为什么不直接 exec 内部 binary：会丢失 bundle 上下文（Info.plist、accessibility 权限、LaunchServices 注册等）。`open -n <bundle>` 由 LaunchServices 处理新实例；`sleep 0.3` 是关键——`NSApp.terminate` 比 LaunchServices 起新进程快，没有这层延迟就只剩"应用退出"了。

### 4.5 打包：本地构建、ad-hoc 签名

`build.sh` 流程：
1. `swift build -c release`
2. 组装 `.app` 目录结构
3. `codesign --force --deep --sign -`（ad-hoc 签名，绕过 Apple Silicon 的 quarantine）

不签名、不分发、不上架。`Info.plist` 设 `LSUIElement=true`，让 App 不出现在 Dock 也不抢焦点。

**自动更新路径上的二次签名**：`update_helper.sh`（`Resources/update_helper.sh`，`ditto` 把新 bundle 拷到安装路径之后）在 `open -n` 之前对最终落盘的 `.app` 再跑一次 `codesign --force --deep --sign -`。ad-hoc 签名是按"签名时那批字节"绑定的，DMG 经 `hdiutil attach` 挂载再 `ditto` 落到用户机器上之后，Gatekeeper 把它当成"来自未识别开发者"，触发"打开方式"系统设置拦截。在**安装位置**重新签一次，签名身份就指向这台机器上的真实副本，升级后不再弹拦截——`build.sh` 的签名为开发者本地运行服务，`update_helper.sh` 的签名为终端用户的升级流程服务，两个签名对象不同、用途不同，**不能合并**。

### 4.6 版本检查：UpdateChecker + UpdatePrompt

**数据流**：
```
   menu/button click ─┐
                      ├─► runUpdateCheck(source:) ─► UpdateChecker.check()
   launch + 5s ───────┘                                     │
                                                            ├─► URLSession
                                                            ├─► parseRelease (JSONSerialization)
                                                            └─► classify (semver 比较)
                                                                       │
                                                                       ▼
                                                       Result { updateAvailable | upToDate
                                                               | skipped | failed }
                                                                       │
                                                                       ▼
                                                       UpdatePrompt.show(_:source:)
                                                       ─────────────────────────
                                                       updateAvailable: 去下载 / 稍后 / 跳过
                                                       upToDate     (manual only): 已是最新
                                                       failed       (manual only): 无法检查
                                                       skipped / background: 静默
```

**端点**：默认 `https://api.github.com/repos/nerozhao/yaotong/releases/latest`（`UpdateChecker.defaultRepo` 常量，运行时读 `YT_UPDATE_REPO` 环境变量可覆盖）。解析只看 `tag_name` / `html_url` / `body` 三个字段，端点无关 — 把 URL 换成自家 JSON 文件也能工作。

**触发时机**（无节流）：
- **后台**：启动后 5s 跑一次，仅在发现新版本时弹"去下载/稍后/跳过"；之后不自动重跑——关掉 app 再启动才会重跑
- **手动**：菜单/主界面的"检查更新…"每次都直接打网络，弹窗（`upToDate` / `failed` 也都弹），给用户即时反馈

为什么没有节流：GitHub Releases API 的未鉴权限制是 60 req/h/IP，单用户每天启动 app 几十次也不会触顶。节流的复杂度（lastCheck 时间戳、UI 上"刚查过"的状态、用户连点看不到结果的困惑）不值得为这点配额买账。

**skipped 持久化**：点过"跳过该版本"的版本号写到 `UserDefaults.yaotong.update.skippedVersion`，远程版本号与之相等时返回 `.skipped(info)`，`UpdatePrompt` 永远不弹。卸载/重装 app 不清 UserDefaults，所以"跳过 v0.3.0"会在后续版本都生效——直到 v0.4.0 出现。

**semver 比较**（`UpdateChecker.isNewer(remote:current:)`）：
- 数字分量按 `[major, minor, patch]` 整数比较，缺位补 0
- `0.10.0 > 0.9.0`（整型比较，不是字符串字典序）
- `1 > 0.9.9`（自动 pad）
- `-prerelease` / `+build` 后缀剥离（不参与排序）
- 任一端解析失败返回 `false`（宁可漏报不可误报）

**为什么后台静默、手动全弹**：后台检查是 app 自发的，弹"已是最新版本"会变成"每天启动都被告知一遍"，变成噪音。手动点击是用户主动行为，期待看见结果——"没结果 = 没响应 = 按钮坏了"。

**测试覆盖**（`UpdateCheckerTests`，16 个用例）：
- `stripTagPrefix` / `isValidVersion` 边界（含 `1..2` / `.1.0` / `1.0.0+build.42` 等历史上让 `split` 默认 `omittingEmptySubsequences: true` 误判的输入）
- `isNewer` 真假值矩阵
- `parseRelease` 全字段 / 缺字段 / 各种 malformed
- `classify` 三种结果（updateAvailable / upToDate / skipped）
- `shouldShow` 4 源 × 4 结果的弹/不弹决策矩阵
- `State` 在 `UserDefaults` 套件里 round-trip

### 4.7 系统通知：Notifier

`Notifier`（[Sources/Yaotong/Notifier.swift](Sources/Yaotong/Notifier.swift)）封装 `UNUserNotificationCenter.current()`，是图标颜色之外的第二提醒通道——菜单栏图标被遮挡时、用户视线不在屏幕顶部时，banner 仍能进通知中心。

**事件 → 通知的映射**（在 `AppDelegate.tick()` 末尾的 `switch` 里完成，状态机保持纯函数）：

| 状态机事件 | 通知动作 |
|---|---|
| `overtimeReached(elapsed:)` | `Notifier.notifyOvertime(elapsed:)` — **先清掉旧通知，再弹新通知**（保证通知中心最多只有一条） |
| `workSessionReset` | `Notifier.clearDelivered()` — 用户休息够了，清掉 |

只有这两个事件驱动通知——`AppDelegate` **不**在启动、休眠、唤醒、阈值变化时主动清通知。

**提醒前清理的结构性保证**：`notifyOvertime` 内部在 `add` 之前先调 `center.removeAllDeliveredNotifications()`——这样不管状态机因为什么情况再次进入超时，通知中心都不会堆多条。配合固定 `identifier = "yaotong.overtime"`，重复请求本身就会被替换为同一通知条目，叠加清理前置等于双保险。

**`workSessionReset` → clear 是 UX 加分项**：从结构性上看，下一次 `overtimeReached` 自然会清掉——这条 case 唯一的价值是"用户真的去休息了，通知应该立刻消失"，让通知更贴近"我去做该做的事"这个反馈循环。

**为什么 `LSUIElement=true` 下也能用**：`UNUserNotificationCenter` 不关心 app 的 activation policy，对 accessory / agent 形态一视同仁。不需要 `Info.plist` 改动——`build.sh` 已有的 ad-hoc 签名 + 固定 bundle id (`local.yaotong.app`) 是必要前提，但都是现有配置。

**测试钩子**（`static var`）：`notifyOvertimeCallCount` / `clearDeliveredCallCount` / `lastNotifiedElapsedSeconds` / `didRequestAuthorization` / `testBypassCenter`。单元测试在 `setUp` 里清零 + 设 `testBypassCenter = true` 短路掉对 `UNUserNotificationCenter.current()` 的访问（headless test binary 调 `current()` 会抛 `NSInternalInconsistencyException`）。**不**在 smoke test 里断言 `UNUserNotificationCenter` 的实际交付——它需要用户授权 + 通知守护进程，headless 跑不出来。

**未做的事**（P2+ 候选）：
- 无通知中心类别 / 按钮 / 自定义声音——默认 banner + `sound: .default` 够用
- 无"勿扰时段" / 专注模式联动
- 无通知偏好开关——保持单一开关的简洁哲学
- 不响应系统休眠 / 唤醒 / 阈值变化 / 启动——通知就是"工作时间到了" + 休息判定命中时清掉，再简单不过

---

## 5. CLI 标志

| 标志 | 作用 |
|------|------|
| `--smoke-test` | 运行所有 §6.2 集成场景，报告写入 `/tmp/yaotong-smoke.log`，退出码反映失败数 |

---

## 6. 构建与测试

```bash
./build.sh release                          # 出 build/腰痛.app
open build/腰痛.app                         # 启动 GUI
swift test                                  # 41 单元测试
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test   # 集成测试
```

---

## 7. 耗电优化（电池友好设计）

| 优化点 | 旧实现 | 新实现 | 节省 |
|--------|--------|--------|------|
| `CGEventSource` 调用 | 7 次/tick（始终查 7 个类型） | 1 次/tick（无 per-type tracking） | **~7×** |
| `NSImage` 分配 | 2 次/tick（每状态各一次） | 3 次/启动（缓存复用：white/red/blue） | **~3600×** |
| `os_log` 系统调用 | 每次活动事件 1 次 | 只写状态机事件（按需）+ 启动 sentinel + 休眠 gap | 大幅下降 |
| Timer wakeup | 0 tolerance | 100ms tolerance，允许系统合并 | 小幅下降 |
| 超时闪烁 | n/a | 仅在 `previous != .overtime` 那次 tick 跑一次 0.18s × 5 步的 Timer；长超时期间 0 开销 | 0 持续成本 |

---

## 8. 已知坑 / TODO

- **Swift 6 @MainActor**：`ObservableObject` + Timer callback 的组合需要 `MainActor.assumeIsolated` 显式标注，否则 Swift 6 严格并发检查会报错。
- **onChange API**：`onChange(of:initial:_:)` 是 macOS 14+，目标 macOS 12 用旧签名 `onChange(of:) { newValue in ... }`。
- **窗口位置**：首次打开 NSWindow 时若用 `center()`，在多屏配置下可能定位到屏外 → 改用 `NSScreen.main.visibleFrame` 手动算中心。
- **GitHub Release asset 文件名不能用中文**：`gh release upload build/腰痛-0.3.0.dmg` 上去后，asset 在页面和下载 URL 里都变成 `-0.3.0.dmg`——非 ASCII 字节被 GitHub 的 asset 路径处理吞掉。`dmg.sh` 默认用 `${APP_NAME}-${VERSION}.dmg`（英文 `Yaotong-…`），**不要** 改成 `${APP_DISPLAY_NAME}-${VERSION}.dmg`（中文 `腰痛-…`）。`.app` bundle 本身保持 `腰痛.app` 不动——只有投递用的 DMG 文件名需要 ASCII-safe。

---

## 9. 修订记录（技术）

完整修订历史见 `git log`。本文档是 2026-06-08 的最终版，反映当前实现：

**功能**
- `StateMachine`：墙钟工作 + 休息空闲 + `waitingForActivity` 门
- `ActivityMonitor`：CGEventSource，sample() 返回 `idle`，1 call/tick 不区分活动类型
- `StatusBarController`：`circle.fill` 18pt，红/蓝通过 `paletteColors` 烧进 image，**三个 NSImage 构造一次后缓存**；`.overtime` 入口跑 0.18s × 5 步的红/空闪烁再稳定
- `StatusState` 升级为**三态**（`.working` / `.overtime` / `.rested`）：休息判定命中、`handleSleepWake` 后返回 `.rested`，让 UI 切到蓝色；用户下一次活动后回到 `.working`（白色）
- `MainWindowController`：启动后自动弹出，SwiftUI + AppKit 桥接；**Dock 图标随窗口状态切换**（`.regular` ↔ `.accessory`）
- 状态机事件（`workSessionStarted` / `workSessionReset` / `overtimeReached`）通过 `os_log` 写入 `local.yaotong` subsystem
- **重启入口**：主界面 + 菜单的"重启 腰痛"按钮；`sh -c "sleep 0.3 && open -n <bundle>" + NSApp.terminate`
- **Dock 图标**：构建时由 `Resources/generate_icon.swift` 生成 `AppIcon.png`（白底 + 蓝色填充圆，80% 直径）→ `Info.plist` `CFBundleIconFile = AppIcon` → 烧进 .app bundle
- **暂停不持久化**：`isPaused` 是纯内存属性，每次启动默认 `false`（运行中）
- **休息时长选项**：`[1, 2, 5, 10, 15, 20, 30, 45, 60]` 分钟（多了 2 分钟档）
- **活动类型日志**（12 种 CGEventType × 5s 节流）—— 移除（高频噪音，状态机事件已覆盖）
- **休眠 / 唤醒处理**：`StateMachine.handleSleepWake()` 把"系统睡过了"当"已充分休息"——`workTime = 0` + 挂等待活动门，**状态机返回 `.rested` 让图标立刻变蓝**。`AppDelegate` 用 wall-clock gap（>2s）+ `NSWorkspace.didWakeNotification` 双路检测，互为兜底
- **版本检查**：`UpdateChecker`（async 网络 + semver + `skippedVersion` 持久化）+ `UpdatePrompt`（NSAlert 渲染）。启动 5s 后后台静默检查（无节流——GitHub 未鉴权 60 req/h/IP 远高于单用户启动频率），仅在发现新版本时弹窗。菜单/主界面手动点击走完整结果（每次都打网络）。默认查 GitHub Releases API，`YT_UPDATE_REPO=owner/repo` 环境变量覆盖
- **系统消息推送**：`Notifier`（`UNUserNotificationCenter` 包装）——工作计时到达阈值时弹"腰痛提醒"通知，**`notifyOvertime` 内部先 `removeAllDeliveredNotifications` 再 `add`**，结构上保证通知中心最多只有一条；休息判定命中时（`workSessionReset`）也清一次让用户得到"我做了该做的事"的反馈。这两个事件就是通知的全部入口。启动请求通知授权；不监听 `didWakeNotification`、不响应阈值变化、不在休眠/唤醒路径清通知。状态机保持纯函数，事件 → 通知的映射在 `AppDelegate.tick()` 完成。
- **手动重置（"重置计时器"）**：`StateMachine.startFreshSession()`——用户**在场**主动重置入口，清 0 工作/休息计时、**不**挂"等待活动"门、**不**发 `workSessionReset` 事件（避免误清超时通知，下一 tick 自然走 `0→1` emit `workSessionStarted`）。与 `handleSleepWake` 形成对照：后者挂门等下一次输入（系统认为"用户不在"），前者不挂门立即累加（用户主动宣告"我工作"）。`AppDelegate.manualReset()` 同步推 `appState` 两个 `@Published` + `statusBar.setState(.working)` 取消超时闪烁 + `os_log` 写一条；主界面"状态"区"停止腰痛"前 + 菜单栏"停止腰痛"前都加"重置计时器"项，主界面按钮暂停时 `.disabled(!running)`。`SmokeTest` 增 9 个新断言覆盖清零 / 不挂门 / 救援路径（从 `waitingForActivity` 门内释放）。

**已移除（多余设计）**
- 调试面板（`DebugView` / `DebugWindowController` / `LogStore`）
- `AppState.forcedIconState`（仅 SmokeTest 内部自引用，UI 未暴露）
- `ConfigStore.allowedMinuteOptions` 反向兼容别名
- `MainWindowController.refresh()` 空操作
- `ActivityProviding` 协议（无第二个实现者）
- `ActivityMonitor.secondsSinceLastInput()` / `latestActivity()` 双方法（合并成 `sample()`）
- **菜单 emoji**（`🪟` / `🔄` / `⏸` / `▶` / `🚪`）—— 系统字体下渲染与中文标签不协调；菜单项改为纯文字
- 活动类型日志（12 种 CGEventType × 5s 节流）—— 属高频噪音，状态机事件已覆盖；同步移除 `ActivityEvent` / `ActivityEvent.Kind` 及 `SystemActivityMonitor.trackedTypes` / `detectEvent()`
- `UpdateChecker.classifyForTesting` 测试专用包装（合并到 `classify` 直接暴露，单一真相）

**性能调整**
- 1Hz Timer tolerance 0.1s
- `NSImage` 缓存复用
- `CGEventSource` 调用：稳态 1 次/秒
- `os_log` 只写状态机事件（无 per-event 噪音）
