# 腰痛

A tiny macOS menu bar app that turns red when you've been working too long, to
remind you to stand up and stretch.

- **唯一 UI** = 一个菜单栏图标（白色 = 工作中 / 红色 = 超时）。无弹窗、无通知、无声音、无计时文字。
- 点击图标弹出配置菜单：调整工作/休息时长、暂停 1 小时、退出。
- 配置持久化在 `UserDefaults`，重启后保留。
- 通过 `CGEventSource.secondsSinceLastEventType` 查询系统空闲时间，无辅助功能权限，无全局事件监听器。

## 项目结构

```
Sources/Yaotong/
├── main entry        AppDelegate.swift     NSApplicationDelegate + 1Hz tick loop
├── config            ConfigStore.swift     UserDefaults 包装 + 暂停状态
├── logic             StateMachine.swift    纯函数式状态机（working / overtime）
├── signal            ActivityMonitor.swift CGEventSource 包装
├── UI                StatusBarController.swift  NSStatusItem + NSMenu
└── test harness      SmokeTest.swift       --smoke-test 模式，覆盖 §6.3 验收
Tests/YaotongTests/
├── StateMachineTests.swift
└── ConfigStoreTests.swift
Resources/Info.plist                       LSUIElement = true（无 Dock 图标）
build.sh                                   本地构建脚本（不签名、不分发）
```

## 构建

```bash
./build.sh release
# 产出: build/腰痛.app
open build/腰痛.app
```

## 测试

```bash
swift test                                # 14 个单元测试
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test   # 21 个端到端场景
```

`--smoke-test` 模式会驱动 `ConfigStore → StateMachine → StatusBarController`
完整链路，把 `REQUIREMENTS.md §6.3` 的所有验收点都跑一遍，报告写到
`/tmp/yaotong-smoke.log`（因为 `.app` bundle 会丢弃 stdout）。

## 配置

| 参数 | 默认 | 可选值 |
|------|------|--------|
| 工作时长 | 30 分钟 | 5 / 10 / 15 / 20 / 30 / 45 / 60 |
| 休息时长 | 10 分钟 | 5 / 10 / 15 / 20 / 30 / 45 / 60 |
| 暂停时长 | 1 小时 | （固定） |
