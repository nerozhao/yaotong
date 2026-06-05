import SwiftUI
import AppKit

/// Root view of the debug panel. Three tabs:
///   - 配置 — same work/rest/pause settings as the menu bar dropdown, but
///           bound to the same ConfigStore so changes show up everywhere.
///   - 测试 — buttons that force the icon state, toggle logging, clear log.
///   - 日志 — auto-scrolling list of LogStore entries.
struct DebugView: View {

    @ObservedObject var config: ConfigStore
    @ObservedObject var logStore: LogStore
    @ObservedObject var appState: AppState

    @State private var selectedTab: Tab

    init(config: ConfigStore,
         logStore: LogStore,
         appState: AppState,
         initialTab: Tab = .config) {
        self.config = config
        self.logStore = logStore
        self.appState = appState
        self._selectedTab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case config = "配置"
        case test   = "测试"
        case log    = "日志"
        var id: String { rawValue }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ConfigTab(config: config, appState: appState)
                .tabItem { Label("配置", systemImage: "gearshape") }
                .tag(Tab.config)
            TestTab(config: config, logStore: logStore, appState: appState)
                .tabItem { Label("测试", systemImage: "hammer") }
                .tag(Tab.test)
            LogTab(logStore: logStore)
                .tabItem { Label("日志", systemImage: "doc.text") }
                .tag(Tab.log)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

// MARK: - 配置 tab

private struct ConfigTab: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            timerSection
            Form {
                Section("工作时长") {
                    Picker("", selection: $config.workMinutes) {
                        ForEach(ConfigStore.allowedMinuteOptions, id: \.self) { m in
                            Text("\(m) 分钟").tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("休息时长") {
                    Picker("", selection: $config.restMinutes) {
                        ForEach(ConfigStore.allowedMinuteOptions, id: \.self) { m in
                            Text("\(m) 分钟").tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("暂停") {
                    if let until = config.pauseUntil, config.isPaused() {
                        Text("暂停中，恢复时间：\(pauseEndString(until))")
                        Button("取消暂停") {
                            appState.objectWillChange.send()
                            config.pauseUntil = nil
                        }
                    } else {
                        Text("未暂停")
                        Button("暂停 1 小时") {
                            config.pauseUntil = Date().addingTimeInterval(ConfigStore.pauseDuration)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private var timerSection: some View {
        let elapsed = appState.workDurationSeconds
        let threshold = max(1, appState.workThresholdSeconds)
        let isOvertime = elapsed > threshold
        let progress = min(1.0, elapsed / threshold)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatMMSS(elapsed))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isOvertime ? .red : .primary)
                    Text("/ \(formatMMSS(threshold))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if isOvertime {
                        Text("已超时")
                            .font(.headline)
                            .foregroundStyle(.red)
                    } else {
                        Text("工作中")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress)
                    .tint(isOvertime ? .red : .accentColor)
            }
            .padding(8)
        } label: {
            Label("工作计时", systemImage: "clock")
                .font(.headline)
        }
    }

    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func pauseEndString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 测试 tab

private struct TestTab: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var logStore: LogStore
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("图标颜色") {
                HStack(spacing: 12) {
                    Button("强制 工作中（白）") {
                        appState.setForcedState(.working)
                    }
                    Button("强制 超时（红）") {
                        appState.setForcedState(.overtime)
                    }
                    Spacer()
                    Button("恢复自动") {
                        appState.clearForcedState()
                    }
                    .disabled(appState.forcedIconState == nil)
                }
                .padding(8)
            }
            GroupBox("日志") {
                HStack(spacing: 12) {
                    Button(logStore.isLogging ? "停止日志" : "开始日志") {
                        logStore.isLogging.toggle()
                    }
                    Button("清空日志") {
                        logStore.clear()
                    }
                    Spacer()
                    Text("条目：\(logStore.entries.count) / \(LogStore.maxEntries)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(8)
            }
            GroupBox("测试事件") {
                HStack(spacing: 12) {
                    Button("记录 INFO 消息") {
                        logStore.log("这是一条测试 info 消息", level: .info)
                    }
                    Button("记录 WARN 消息") {
                        logStore.log("这是一条测试 warn 消息", level: .warn)
                    }
                    Button("记录 ERROR 消息") {
                        logStore.log("这是一条测试 error 消息", level: .error)
                    }
                }
                .padding(8)
            }
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - 日志 tab

private struct LogTab: View {
    @ObservedObject var logStore: LogStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if logStore.entries.isEmpty {
                        Text("(空 — 试试切换到「测试」标签记录一条消息)")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(logStore.entries) { entry in
                            Text(logStore.formatted(entry))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 1)
                                .id(entry.id)
                        }
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: logStore.entries.count) { _ in
                // Auto-scroll to the newest entry.
                if let last = logStore.entries.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
