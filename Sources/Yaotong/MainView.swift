import SwiftUI
import AppKit

/// The main interface — opens automatically on launch and can be reopened
/// by clicking the status-bar icon. Two timers at the top (work + rest,
/// running simultaneously) and the same settings as the menu dropdown
/// below. No debug controls — those are gone in this version.
struct MainView: View {

    @ObservedObject var config: ConfigStore
    @ObservedObject var appState: AppState

    private let onQuit: () -> Void
    private let onRestart: () -> Void

    init(config: ConfigStore,
         appState: AppState,
         onQuit: @escaping () -> Void = {},
         onRestart: @escaping () -> Void = {}) {
        self.config = config
        self.appState = appState
        self.onQuit = onQuit
        self.onRestart = onRestart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            workSection
            Divider()
            restSection
            Divider()
            settingsSection
            Divider()
            pauseSection
            HStack {
                Spacer()
                Button("重启 腰痛") { onRestart() }
                Button("退出 腰痛", role: .destructive) { onQuit() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            HStack {
                Spacer()
                Text("v\(AppVersion.display)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(minWidth: 540)
    }

    // MARK: - Work section (primary, large)

    private var workSection: some View {
        let work = appState.workDurationSeconds
        let threshold = max(1, appState.workThresholdSeconds)
        let isOvertime = work >= threshold
        let progress = min(1.0, work / threshold)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatMMSS(work))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
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
            Label("工作计时（自上次休息以来）", systemImage: "laptopcomputer")
                .font(.headline)
        }
    }

    // MARK: - Rest section (secondary)

    private var restSection: some View {
        let rest = appState.restDurationSeconds
        let threshold = max(1, appState.restThresholdSeconds)
        let progress = min(1.0, rest / threshold)
        let isRested = rest >= threshold
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatMMSS(rest))
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isRested ? .green : .primary)
                    Text("/ \(formatMMSS(threshold))")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if isRested {
                        Text("已休息")
                            .font(.headline)
                            .foregroundStyle(.green)
                    } else {
                        Text("未休息")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: progress)
                    .tint(isRested ? .green : .accentColor)
            }
            .padding(8)
        } label: {
            Label("休息计时（鼠标未动时长）", systemImage: "moon.zzz")
                .font(.headline)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        Form {
            Section("工作时长") {
                Picker("", selection: $config.workMinutes) {
                    ForEach(ConfigStore.allowedWorkMinuteOptions, id: \.self) { m in
                        Text("\(m) 分钟").tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("休息时长") {
                Picker("", selection: $config.restMinutes) {
                    ForEach(ConfigStore.allowedRestMinuteOptions, id: \.self) { m in
                        Text("\(m) 分钟").tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Pause section

    private var pauseSection: some View {
        let running = !config.isPaused
        return GroupBox {
            HStack {
                Text(running ? "运行中" : "已暂停")
                    .font(.headline)
                Spacer()
                Button(running ? "暂停腰痛" : "开始腰痛") {
                    config.togglePause()
                }
            }
            .padding(8)
        } label: {
            Label("状态", systemImage: "power")
                .font(.headline)
        }
    }

    // MARK: - Formatting

    private func formatMMSS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
