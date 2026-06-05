# 腰痛

macOS 菜单栏健康提醒小工具。持续工作达到阈值后，图标变红提醒你起身活动；离开工位休息一段时间后自动归零。

> 名字"腰痛"直白点出久坐对腰部的危害——比"久坐提醒"更扎眼。

## 功能

- 菜单栏图标常驻：白色 `circle.fill` = 工作中，红色 = 超时。仅靠颜色变化，不弹窗不响铃。
- 工作计时是**墙钟**（鼠标不动也累加），但休息判定命中后清零并挂"等待活动"门——必须**下一次输入**才重新开始。
- 系统休眠 / 唤醒时，自动视为已充分休息，唤醒后等用户输入才恢复计时。
- 启动后自动弹出主界面：双计时器 + 工作 / 休息时长 Picker + 暂停开关 + 重启 / 退出按钮。
- 点击图标弹出下拉菜单：显示主界面、工作/休息时长、暂停/开始、重启、退出。
- 配置（工作/休息时长）持久化在 `UserDefaults`；暂停状态**不持久化**，每次启动默认运行中。
- 活动检测走 `CGEventSource.secondsSinceLastEventType`，1 次 / 秒，无辅助功能权限，无全局事件监听器。

## 系统要求

macOS 12+ · Apple Silicon / Intel 通用 · 仅本地运行（不签名、不上架、不分发）

## 构建

```bash
./build.sh release
open build/腰痛.app
```

`build.sh` 会跑 `swift build`、组装 `.app` 目录、用 `generate_icon.swift` 渲染 1024×1024 的 Dock 图标 PNG 烧进 bundle，最后 ad-hoc 签名。

## 测试

```bash
swift test                                            # 25 个单元测试
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test    # 32 个端到端场景
```

`--smoke-test` 模式驱动完整 `ConfigStore → StateMachine → StatusBarController` 链路，覆盖产品文档 `REQUIREMENTS.md §6.3` 的所有验收点，报告写到 `/tmp/yaotong-smoke.log`。

## 项目结构

```
Sources/Yaotong/
├── AppDelegate.swift            NSApplicationDelegate + 1Hz tick + 休眠/唤醒检测
├── AppIcon.swift                Dock 图标运行时兜底
├── AppVersion.swift             版本号常量
├── ConfigStore.swift            UserDefaults 包装 + 暂停状态（纯内存）
├── StateMachine.swift           纯函数式状态机 + 等待活动门 + 休眠处理
├── ActivityMonitor.swift        CGEventSource 包装（1 call/tick）
├── AppState.swift               工作/休息计时实时值
├── StatusBarController.swift    NSStatusItem + NSMenu + 缓存 SF Symbol
├── MainView.swift               主界面 SwiftUI 视图
├── MainWindowController.swift   NSWindow + SwiftUI 桥接 + Dock 联动
└── SmokeTest.swift              --smoke-test 模式
Tests/YaotongTests/
├── StateMachineTests.swift
└── ConfigStoreTests.swift
Resources/
├── Info.plist                   LSUIElement = true
├── AppIcon.png                  构建时生成的 Dock 图标
└── generate_icon.swift          Core Graphics 图标渲染脚本
```

## 配置

| 参数 | 默认 | 可选值 |
|------|------|--------|
| 工作时长 | 30 分钟 | 2 / 5 / 10 / 15 / 20 / 30 / 45 / 60 |
| 休息时长 | 10 分钟 | 1 / 2 / 5 / 10 / 15 / 20 / 30 / 45 / 60 |

## 查看日志

```bash
log show --predicate 'subsystem == "local.yaotong"' --info --last 5m
```

或在「控制台.app」按 subsystem `local.yaotong` 过滤。会看到状态机事件（`工作会话开始` / `休息判定` / `超时判定` / 休眠唤醒）。

## 详细文档

- `REQUIREMENTS.md` — 产品需求、用户场景、UI 行为定义、验收清单
- `TECHNICAL.md` — 架构、文件结构、关键决策、踩坑、耗电优化

## 开发说明

本项目用 [Claude Code](https://claude.com/claude-code)（Anthropic 出品的 CLI 编程助手，基于 Claude 系列模型） + [MiniMax](https://MiniMax.chat) 自动化开发——从需求对话、代码生成、测试验证到文档撰写全程由 AI 协作完成，开发者负责产品决策和验收。

## 版权

仅个人使用，不开源，不分发。
