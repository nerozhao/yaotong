# 腰痛 - 技术方案

> 本文档描述工程实现：架构、文件结构、关键技术选型、构建测试流程、踩过的坑。
> 产品需求、用户场景、UI 行为定义见 [REQUIREMENTS.md](REQUIREMENTS.md)。

---

## 1. 技术栈

| 维度 | 选择 |
|------|------|
| 平台 | macOS 12+（LSUIElement 菜单栏独占） |
| 语言 | Swift 5.9+ |
| UI | AppKit（NSStatusItem、NSMenu）+ SwiftUI（调试窗口） |
| 包管理 | Swift Package Manager |
| 配置存储 | `UserDefaults`（`yaotong.workMinutes` / `yaotong.restMinutes` / `yaotong.pauseUntil`） |
| 活动检测 | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: 0xFFFFFFFF)` |
| 图标 | SF Symbol `circle.fill`，白色 template / 红色 `paletteColors: [.systemRed]` |

---

## 2. 架构

```
AppDelegate  ──┬─► ConfigStore (UserDefaults, ObservableObject)
               ├─► StateMachine (pure, lastEvent 输出)
               ├─► ActivityMonitor (CGEventSource wrapper)
               ├─► LogStore (ObservableObject, 500 条环形缓冲)
               ├─► AppState (forcedIconState / 实时计时)
               ├─► StatusBarController (NSStatusItem + NSMenu)
               └─► DebugWindowController (NSWindow + NSHostingController)
                       └─► DebugView (SwiftUI TabView: 配置/测试/日志)
```

1 Hz Timer → `tick()` → 读 idle 时间 → `stateMachine.tick()` → 取 `lastEvent` → 写 `LogStore` → 推 `appState.workDurationSeconds` → `statusBar.setState()` 渲染图标。

---

## 3. 文件结构

```
Sources/Yaotong/
├── AppDelegate.swift            NSApplicationDelegate + 1Hz tick + 启动装配
├── main entry                   （AppDelegate 顶部 @main）
├── ConfigStore.swift            UserDefaults 包装，ObservableObject
├── StateMachine.swift           纯状态机，输出 StatusState + StateMachineEvent
├── ActivityMonitor.swift        CGEventSource 包装（protocol ActivityProviding）
├── StatusBarController.swift    NSStatusItem + NSMenu + SF Symbol 渲染
├── AppState.swift               forcedIconState / workDurationSeconds / 阈值
├── LogStore.swift               环形缓冲，多线程安全
├── DebugView.swift              SwiftUI TabView
├── DebugWindowController.swift  NSWindow + NSHostingController
└── SmokeTest.swift              --smoke-test 模式，驱动 §6.2 集成测试
Tests/YaotongTests/
├── StateMachineTests.swift      状态机 + 事件 + workDuration
├── ConfigStoreTests.swift       持久化 / 暂停 / 切换
├── LogStoreTests.swift          环形缓冲 / 异步 / 格式化
└── AppStateTests.swift          forcedIconState 读写
Resources/Info.plist             LSUIElement=true, NSPrincipalClass=NSApplication
build.sh                         本地打包脚本
Package.swift                    SwiftPM 清单
```

---

## 4. 关键技术决策

### 4.1 活动信号：CGEventSource 而非全局监听

**结论**：只调用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: 0xFFFFFFFF)`，**不安装**任何 `CGEventTap` / `NSEvent monitor`。

**原因**：
- 不需要计算鼠标移动量或时间窗
- 不需要申请辅助功能（Accessibility）权限
- 不污染用户的事件流（事件监听有性能影响）
- 一次系统调用，零状态

`0xFFFFFFFF` 是 `kCGAnyInputEventType` 的原始值 —— Swift overlay 没有给 `CGEventType.any` 这样的 case，需要手动构造。

### 4.2 图标渲染：paletteColors 烧进 image

**坑**：macOS `NSStatusItem.button.contentTintColor` **不**对 SF Symbol 生效。设了 `isTemplate = false` + `contentTintColor = .systemRed` 后，图标显示的是 SF Symbol 的原始黑色，**不是红色**。

**修复**：用 `NSImage.SymbolConfiguration(paletteColors: [.systemRed])` + `withSymbolConfiguration` 把红色烧进 `NSImage` 本身。

```swift
let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
let tinted = base.withSymbolConfiguration(config)
tinted.isTemplate = false
```

**测试**：smoke test 读 icon 的 bitmap 像素，断言 >30% 的不透明像素 R 通道占主导（`r > 0.5 && r > g+0.15 && r > b+0.15`）。把 icon 状态直接 dump 到 `/tmp/yaotong-overtime-icon.png` / `/tmp/yaotong-working-icon.png` 供视觉验证。

### 4.3 状态机：纯函数 + lastEvent 旁路输出

`StateMachine.tick(now:idleSeconds:isPaused:)` 返回 `StatusState`，把"为什么"放在 `lastEvent: StateMachineEvent` 属性上。`AppDelegate` 读 `lastEvent`，非 `.none` / 非 `.paused` 时写一行中文到 `LogStore`。

事件类型：
- `workSessionStarted` —— 工作会话首次启动
- `workSessionReset(idleSeconds:)` —— 休息判定命中
- `overtimeReached(elapsed:)` —— 跨过工作阈值
- `paused` —— 暂停中（不写日志，否则每秒刷一遍）
- `.none` —— 常规 tick

### 4.4 调试面板：SwiftUI + AppKit 桥接

- `NSHostingController` 把 `DebugView` 塞进 `NSWindow.contentViewController`
- `AppState.forcedIconState` 覆盖 `stateMachine` 的输出 —— 测试 Tab 的"强制超时"按钮立即生效
- `LogStore` 异步写（后台 queue → main 发布），500 条环形缓冲
- 配置 Tab 的"工作计时"通过 `appState.workDurationSeconds` / `workThresholdSeconds` 实时刷新

### 4.5 打包：本地构建、ad-hoc 签名

`build.sh` 流程：
1. `swift build -c release`
2. 组装 `.app` 目录结构
3. `codesign --force --deep --sign -`（ad-hoc 签名，绕过 Apple Silicon 的 quarantine）

不签名、不分发、不上架。`Info.plist` 设 `LSUIElement=true`，让 App 不出现在 Dock 也不抢焦点。

---

## 5. 调试模式 CLI 标志

| 标志 | 作用 |
|------|------|
| `--smoke-test` | 运行所有 §6.2 集成场景，报告写入 `/tmp/yaotong-smoke.log`，退出码反映失败数 |
| `--smoke-output=/path` | 自定义 smoke test 报告路径（默认 `/tmp/yaotong-smoke.log`） |
| `--show-debug` | 启动后自动打开调试窗口（默认在配置 Tab） |
| `--show-debug=test` | 打开调试窗口，跳到测试 Tab |
| `--show-debug=log` | 打开调试窗口，跳到日志 Tab |

---

## 6. 构建与测试

```bash
./build.sh release                 # 出 build/腰痛.app
open build/腰痛.app                # 启动 GUI
swift test                         # 30 单元测试
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test   # 26 集成测试
```

---

## 7. 已知坑 / TODO

- **辅助功能权限**：调试窗口用 AppleScript 定位时需要辅助功能权限（已默认开启，UI 操作时无影响）
- **窗口位置**：首次打开 NSWindow 时 `center()` 在某些多屏配置下可能定位到屏外，需要 `MainActor` 标记避免并发警告
- **Swift 5 @MainActor**：`ObservableObject` + Timer callback 的组合需要 `MainActor.assumeIsolated` 显式标注，否则 Swift 6 严格并发检查会报错
- **onChange API**：`onChange(of:initial:_:)` 是 macOS 14+，目标 macOS 12 用旧签名 `onChange(of:) { newValue in ... }`

---

## 8. 修订记录（技术）

- 2026-06-05: 初版（SwiftPM + AppKit + SwiftUI 混合架构）
- 2026-06-05: 修复 overtime 图标显示为黑色的 bug（macOS `contentTintColor` 对 SF Symbol 失效，改用 `paletteColors` 烧进 image）
- 2026-06-05: 加入调试面板（SwiftUI 3-Tab，覆盖原"无窗口"决策）
- 2026-06-05: StateMachine 增加 `lastEvent` 输出，AppDelegate 把状态机事件写到 LogStore
- 2026-06-05: 配置 Tab 加入"工作计时"实时显示（MM:SS / MM:SS + 进度条）
- 2026-06-05: 图标改为 `circle.fill`（solid circle），pointSize 20 → 16
- 2026-06-05: 默认值和选项各 +1 分钟（30→31, 10→11, 选项 6/11/16/21/31/46/61）
