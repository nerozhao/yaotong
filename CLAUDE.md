# 腰痛 — Claude 工作小抄

> 这是给 Claude Code 的**速查**，不是文档替代品。完整资料见下方三份主文档。
> 写本文件的原则：只放 AI 高频要用的"操作要点"，避免与主文档重复。

## 必读主文档

| 文档 | 内容 | 何时读 |
|---|---|---|
| [README.md](README.md) | 项目介绍、构建/测试命令、配置项 | 第一次接触项目 |
| [REQUIREMENTS.md](REQUIREMENTS.md) | 产品需求、状态机语义、UI 行为、产品决策记录 | 改产品行为前 |
| [TECHNICAL.md](TECHNICAL.md) | 架构、文件结构、关键技术决策、踩过的坑 | 改实现前 |

## 技术栈（速记）

Swift 5.9+ · AppKit + SwiftUI · SwiftPM · macOS 12+ · `LSUIElement=true`（菜单栏独占）· `os_log` subsystem `local.yaotong`

## 构建 / 测试 / 日志

```bash
./build.sh release                                              # 打包 release
build/腰痛.app/Contents/MacOS/Yaotong --smoke-test              # 端到端
swift test                                                       # 单元测试
log show --predicate 'subsystem == "local.yaotong"' --info --last 5m   # 查日志
```

## 核心文件（高频修改）

- 状态机（**纯函数**，最容易改坏）：[Sources/Yaotong/StateMachine.swift](Sources/Yaotong/StateMachine.swift)
- 1Hz tick 驱动：[Sources/Yaotong/AppDelegate.swift](Sources/Yaotong/AppDelegate.swift)
- 菜单栏图标（**构造一次缓存复用**）：[Sources/Yaotong/StatusBarController.swift](Sources/Yaotong/StatusBarController.swift)
- 配置持久化（`isPaused` **不**持久化）：[Sources/Yaotong/ConfigStore.swift](Sources/Yaotong/ConfigStore.swift)
- 主界面：[Sources/Yaotong/MainView.swift](Sources/Yaotong/MainView.swift)
- 系统通知（`UNUserNotificationCenter` 包装）：[Sources/Yaotong/Notifier.swift](Sources/Yaotong/Notifier.swift)
- 集成 smoke：[Sources/Yaotong/SmokeTest.swift](Sources/Yaotong/SmokeTest.swift)

## 关键约束（踩过的坑）

1. **状态机只看 `idleSeconds < 1.0`**，不区分活动类型——不要加事件类型分支。
2. **工作计时是墙钟**（鼠标不动也累加）；休息判定命中后被"等待活动"门暂停，等用户**下一次输入**才释放。
3. **超时入口要跑 0.18s × 5 步红/空闪烁**再稳定为红色——视觉锚定阈值点。
4. **`isPaused` 不持久化**：每次启动默认运行中，别加 `UserDefaults` 同步。
5. **菜单无 emoji**（系统字体下与中文标签不协调），图标用 SF Symbol `circle.fill`。
6. **状态机事件用 `os_log`**（subsystem `local.yaotong`、category `activity`），**不写活动类型日志**（已移除，会变噪音）。
7. 用户可见文案**中文为主**（"腰痛"、"工作计时"、"停止腰痛"），代码标识符英文。
8. **不要照搬大文档内容进 CLAUDE.md**——本文件是速查，重复会浪费上下文窗口。
9. **通知事件在 `AppDelegate.tick()` 末尾的 switch 里 dispatch**：`overtimeReached` → `Notifier.notifyOvertime(elapsed:)`（**内部先 `removeAllDeliveredNotifications` 再 `add`**，结构上保证通知中心最多一条）；`workSessionReset` → `Notifier.clearDelivered()`。这两个事件就是通知的全部入口——不响应休眠/唤醒/阈值变更/启动。**不要**让状态机直接耦合 `UNUserNotificationCenter`（状态机保持纯函数，单元测试才能 headless 跑）。

## 修改前自问（同步更新主文档）

| 改动类型 | 同步更新 |
|---|---|
| 状态机语义 / 计时逻辑 | [REQUIREMENTS.md §2.2](REQUIREMENTS.md) + [TECHNICAL.md §4](TECHNICAL.md) |
| 图标 / UI 行为 | [REQUIREMENTS.md §5](REQUIREMENTS.md) |
| 配置 key 改动 | 检查 [ConfigStore.swift](Sources/Yaotong/ConfigStore.swift) 迁移逻辑 |
| 公共 API 改动 | 更新 [TECHNICAL.md §3](TECHNICAL.md) 文件结构表 |
| 产品决策（新增/推翻） | 追加到 [REQUIREMENTS.md §7](REQUIREMENTS.md) 决策表 |
| 版本号 bump | `Resources/Info.plist`（`CFBundleShortVersionString` + `CFBundleVersion`） + 写一条 `git tag`（若要） |

## 结束会话协议

> **本节是给 Claude 的硬性指令，不是给人类看的提示。**

会话结束（即将不再回复用户）前必须自检：

1. **如果本次 session 修改了 Swift 代码**（`Sources/Yaotong/` 或 `Tests/` 或 `Resources/Info.plist`）：
   - 必须跑 `./build.sh release`，**确认构建成功**才能结束。
   - 若构建失败：修复后重跑，直到通过——不要把失败状态留给用户。
   - 不在主文档更新、不改任何代码的纯文档 session 跳过此步。
2. **如果同时改了主文档**（README / REQUIREMENTS / TECHNICAL），确认交叉引用（`§X` 章节号、文件名）没断。
3. **如果新增/删除了文件**，更新 [TECHNICAL.md §3](TECHNICAL.md) 文件结构表。

## Loop stop rules

### 停止条件

循环在以下任一条件成立时停止：

1. ALL GREEN：所有检查通过。停止，附上每项检查的通过证明。
2. 轮次用尽：达到 5 轮上限。停止，报告仍失败的项、每轮尝试了什么、为什么没成功。
3. 同一失败连续两轮：builder 在猜，不是在修。停止，升级给我。
4. 回归：修复导致之前通过的检查失败。停止，说明改了什么导致了回归。
5. 无实质进展：连续 2 轮失败项数量没有减少。停止，可能任务范围过大，
   需要拆分成更小的子任务。
6. 疑似超出能力边界：builder 反复尝试但失败原因涉及它无法访问的外部依赖
   或环境问题。停止，报告阻塞点。

### 红线

- 永远不在没有 checker 输出的情况下报告成功。
- 永远不弱化、删除、跳过检查来达到 ALL GREEN。
- 永远不修改 checker 的工具白名单。

### 升级协议

停止并升级给我时，必须携带以下信息：
- 当前轮次（Cycle N/5）
- 仍失败的项列表
- 每项已尝试过的修复方法
- 你的判断：为什么继续循环不会解决问题