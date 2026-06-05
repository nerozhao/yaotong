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
| 图标 | SF Symbol `circle.fill`，18pt，白色 template / 红色 `paletteColors: [.systemRed]`，**构造一次缓存复用** |
| 日志 | `os_log`，subsystem `local.yaotong`，category `activity`，`.default` 级别；活动类型 5s 节流 |

---

## 2. 架构

```
AppDelegate  ──┬─► ConfigStore (UserDefaults, ObservableObject)
               ├─► StateMachine (pure, lastEvent 输出)
               ├─► ActivityMonitor (CGEventSource 包装)
               ├─► AppState (实时计时, ObservableObject)
               ├─► StatusBarController (NSStatusItem + NSMenu)
               └─► MainWindowController (NSWindow + NSHostingController)
                       └─► MainView (SwiftUI: 工作/休息计时器 + 设置)
```

1 Hz Timer（tolerance 0.1s）→ `tick()` → `activity.sample()` 拿 idle + 可选事件 → `stateMachine.tick()` → 推 `appState` → `statusBar.setState()` 切换缓存 icon → `os_log` 写状态机事件 + 节流后写活动类型。

---

## 3. 文件结构

```
Sources/Yaotong/
├── AppDelegate.swift            NSApplicationDelegate + 1Hz tick + 启动装配
├── ConfigStore.swift            UserDefaults 包装, ObservableObject
├── StateMachine.swift           两个独立计时器 + waitingForActivity 门
├── ActivityMonitor.swift        CGEventSource 包装, sample() 返回 (idle, event)
├── StatusBarController.swift    NSStatusItem + NSMenu + 缓存 SF Symbol
├── AppState.swift               work/rest 时长 + 阈值 (4 个 @Published)
├── MainView.swift               主界面 SwiftUI 视图
├── MainWindowController.swift   NSWindow + NSHostingController, 启动后自动打开
└── SmokeTest.swift              --smoke-test 模式, 驱动 §6.2 集成测试
Tests/YaotongTests/
├── StateMachineTests.swift      计时器 + 门 + 事件 + 跨阈值
└── ConfigStoreTests.swift       持久化 / 暂停 / 切换
Resources/Info.plist             LSUIElement=true, NSPrincipalClass=NSApplication
build.sh                         本地打包脚本
Package.swift                    SwiftPM 清单
```

---

## 4. 关键技术决策

### 4.1 活动信号：CGEventSource 而非全局监听

**结论**：只调用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: <specific>)`，**不安装**任何 `CGEventTap` / `NSEvent monitor`。

**原因**：
- 不需要申请辅助功能（Accessibility）权限
- 不污染用户的事件流（事件监听有性能影响）
- 一次系统调用，零状态

**性能关键**：`SystemActivityMonitor.sample()` 基线 1 个 CG 调用/tick（`kCGAnyInputEventType` 的"any input"读数），**仅在读数下降的那一 tick** 才追加最多 7 个 per-type 调用来识别种类。稳态 1 call/tick ≈ 3600 calls/小时（旧实现 7 call/tick ≈ 25200 calls/小时，**省 6×**）。

`SystemActivityMonitor` 在活动发生的 tick 才会查询多个 `CGEventType`（`.leftMouseDown`、`.rightMouseDown`、`.otherMouseDown`、`.mouseMoved`、`.keyDown`、`.scrollWheel`、`.tabletPointer`），跟前一次的 `secondsSinceLastEventType` 对比：
- 数值下降 → 该类型刚发生了一次事件
- 通过 `os_log` 写入系统日志（subsystem `local.yaotong`, category `activity`，级别 `.default`），格式如：

```
Yaotong: [local.yaotong:activity] 检测到活动：鼠标点击
Yaotong: [local.yaotong:activity] 检测到活动：键盘按键
Yaotong: [local.yaotong:activity] 检测到活动：滚轮滚动
Yaotong: [local.yaotong:activity] 检测到活动：鼠标移动
Yaotong: [local.yaotong:activity] 检测到活动：触摸板
```

活动类型仅用于日志，**不**影响判定逻辑（判定只看 `idleSeconds < 1.0`）。

在「控制台.app」中按 `subsystem:local.yaotong` 或 `process:Yaotong` 过滤即可看到这些条目；命令行：

```bash
log show --predicate 'subsystem == "local.yaotong"' --info --last 5m
```

`0xFFFFFFFF` 是 `kCGAnyInputEventType` 的原始值 —— Swift overlay 没有给 `CGEventType.any` 这样的 case，需要手动构造。

### 4.2 图标渲染：paletteColors 烧进 image + 缓存

**坑 1（颜色）**：macOS `NSStatusItem.button.contentTintColor` **不**对 SF Symbol 生效。设了 `isTemplate = false` + `contentTintColor = .systemRed` 后，图标显示的是 SF Symbol 的原始黑色，**不是红色**。

**修复 1**：用 `NSImage.SymbolConfiguration(paletteColors: [.systemRed])` + `withSymbolConfiguration` 把红色烧进 `NSImage` 本身。

**坑 2（耗电）**：旧实现每 tick 调用 `workingIcon()` / `overtimeIcon()` 工厂方法，里面走一遍 `NSImage(systemSymbolName:)` + `withSymbolConfiguration()` —— 每秒两次 NSImage 分配，每小时 7200 次。状态基本不变，纯粹浪费。

**修复 2**：`StatusBarController` 在 `init` 里 `makeWorkingIcon()` / `makeOvertimeIcon()` 各算一次，存为 `workingImage` / `overtimeImage` 实例属性；`setState(_:)` 只做一次指针切换。

```swift
private static let iconConfig = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
private let workingImage: NSImage
private let overtimeImage: NSImage

init(...) {
    self.workingImage = StatusBarController.makeWorkingIcon()
    self.overtimeImage = StatusBarController.makeOvertimeIcon()
}

func setState(_ state: StatusState) {
    statusItem.button?.image = (state == .overtime) ? overtimeImage : workingImage
}
```

**测试**：smoke test 读 icon 的 bitmap 像素，断言 >30% 的不透明像素 R 通道占主导（`r > 0.5 && r > g+0.15 && r > b+0.15`）。把 icon 状态直接 dump 到 `/tmp/yaotong-overtime-icon.png` / `/tmp/yaotong-working-icon.png` 供视觉验证。

### 4.3 状态机：墙钟工作 + 休息后的活动门

`StateMachine` 持有两个独立计数器 + 一个门：

- **`workTime` = 自上次休息以来的墙钟时长**。每 tick +1，**不依赖**活动。`restTime` 跨过阈值时被重置为 0，并触发"等待活动"门。
- **`restTime` = 自上次活动以来的空闲时长**。活动时归零，空闲时取系统的 `idleSeconds`。
- **`waitingForActivity`**：布尔门。休息判定命中后置 true，期间 `workTime` 保持 0；下一次活动 tick 释放门，工作下一 tick 重新开始累加。

`tick(now:idleSeconds:isPaused:)` 返回 `StatusState`：
- `overtime`：当 `workTime >= workThreshold`
- `working`：其他

按"刚刚跨过"模式触发事件 `lastEvent: StateMachineEvent`：
- `workSessionStarted` —— `workTime` 从 0 → 1，或"等待活动"门释放后第一 tick
- `workSessionReset(idleSeconds:)` —— `restTime` 跨过休息阈值，重置 `workTime = 0` 并挂起门
- `overtimeReached(elapsed:)` —— `workTime` 跨过工作阈值
- `paused` —— 暂停中
- `.none` —— 常规 tick

按用户要求：工作计时是墙钟（鼠标不动也累加），但休息判定命中后会挂起门直到下一次活动才重新开始。

### 4.4 主界面窗口：SwiftUI + AppKit 桥接 + Dock 联动

- `MainWindowController` 用 `NSHostingController` 把 `MainView` 塞进 `NSWindow.contentViewController`
- 启动后 `DispatchQueue.main.async { mainWindow.open() }` 自动弹出
- 窗口位置用 `NSScreen.main.visibleFrame` 手动计算中心（避免 `center()` 在多屏下落到屏外）
- `MainView` 用 `@ObservedObject` 绑定 `ConfigStore` 和 `AppState`；Picker 改动通过 ConfigStore 写到 UserDefaults
- 关闭主窗口（点 X）不会退出 App；点"退出 腰痛"按钮调用 `NSApp.terminate(nil)`；点"重启 腰痛"按钮调用 `AppDelegate.restartApp()`

**Dock 图标随窗口状态切换**：`Info.plist` 把默认 `LSUIElement=true`（不显示在 Dock）。`MainWindowController.open()` 里把 activation policy 切到 `.regular`（Dock 显示图标，Cmd-Tab 也能切到）；`NSWindow.willCloseNotification` 监听关窗，切回 `.accessory`（回到纯菜单栏模式）。结果：菜单栏永远在，主窗口打开时 Dock 有图标，关闭后图标消失。

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
swift test                                  # 22 单元测试
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test   # 22 集成测试
```

---

## 7. 耗电优化（电池友好设计）

| 优化点 | 旧实现 | 新实现 | 节省 |
|--------|--------|--------|------|
| `CGEventSource` 调用 | 7 次/tick（始终查 7 个类型） | 1 次/tick（仅活动发生瞬间追加 1–12 次） | **~6×** |
| `NSImage` 分配 | 2 次/tick（每状态各一次） | 2 次/启动（缓存复用） | **~3600×** |
| `os_log` 系统调用 | 每次活动事件 1 次 | 活动类型 5s 节流；状态机事件按需 | 大幅下降 |
| Timer wakeup | 0 tolerance | 100ms tolerance，允许系统合并 | 小幅下降 |

---

## 8. 已知坑 / TODO

- **Swift 6 @MainActor**：`ObservableObject` + Timer callback 的组合需要 `MainActor.assumeIsolated` 显式标注，否则 Swift 6 严格并发检查会报错。
- **onChange API**：`onChange(of:initial:_:)` 是 macOS 14+，目标 macOS 12 用旧签名 `onChange(of:) { newValue in ... }`。
- **窗口位置**：首次打开 NSWindow 时若用 `center()`，在多屏配置下可能定位到屏外 → 改用 `NSScreen.main.visibleFrame` 手动算中心。

---

## 9. 修订记录（技术）

完整修订历史见 `git log`。本文档是 2026-06-05 的最终版，反映当前实现：

**功能**
- `StateMachine`：墙钟工作 + 休息空闲 + `waitingForActivity` 门
- `ActivityMonitor`：CGEventSource，sample() 返回 `(idle, event)`，追踪 12 种类型（点击 / 拖拽 / 键 / 修饰 / 系统 / 滚轮 / 移动 / 触摸板）
- `StatusBarController`：`circle.fill` 18pt，红色通过 `paletteColors` 烧进 image，**两个 NSImage 构造一次后缓存**
- `MainWindowController`：启动后自动弹出，SwiftUI + AppKit 桥接；**Dock 图标随窗口状态切换**（`.regular` ↔ `.accessory`）
- 状态机事件（`workSessionStarted` / `workSessionReset` / `overtimeReached`）通过 `os_log` 写入 `local.yaotong` subsystem
- **重启入口**：主界面 + 菜单的"重启 腰痛"按钮；`sh -c "sleep 0.3 && open -n <bundle>" + NSApp.terminate`
- **暂停不持久化**：`isPaused` 是纯内存属性，每次启动默认 `false`（运行中）
- 活动类型日志（`鼠标点击` / `拖拽` / `键盘` / `修饰键` / `系统键` / `滚轮` / `移动` / `触摸板`）5 秒节流
- 工作时间窗口：默认 08:30–18:00；窗口外自动暂停；"开始腰痛" 可手动启动一次；进入窗口时挂容错门

**已移除（多余设计）**
- 调试面板（`DebugView` / `DebugWindowController` / `LogStore`）
- `AppState.forcedIconState`（仅 SmokeTest 内部自引用，UI 未暴露）
- `ConfigStore.allowedMinuteOptions` 反向兼容别名
- `MainWindowController.refresh()` 空操作
- `ActivityProviding` 协议（无第二个实现者）
- `ActivityMonitor.secondsSinceLastInput()` / `latestActivity()` 双方法（合并成 `sample()`）

**性能调整**
- 1Hz Timer tolerance 0.1s
- `NSImage` 缓存复用
- `CGEventSource` 调用 7→1/秒（仅活动发生时追加）
- `os_log` 活动类型 5s 节流
