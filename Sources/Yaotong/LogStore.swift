import Foundation
import Combine

/// One entry in the in-app log shown by the debug panel.
struct LogEntry: Identifiable, Equatable {
    enum Level: String {
        case info, warn, error
        var symbol: String {
            switch self {
            case .info:  return "ℹ️"
            case .warn:  return "⚠️"
            case .error: return "❌"
            }
        }
    }
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String
}

/// Thread-safe, ring-buffered log store. Anything in the app can call `log`
/// from any thread; SwiftUI views observing the store get auto-updates on
/// the main thread.
final class LogStore: ObservableObject {

    /// Maximum number of entries kept in memory. Older entries are dropped.
    static let maxEntries = 500

    @Published private(set) var entries: [LogEntry] = []
    @Published var isLogging: Bool = true

    private let queue = DispatchQueue(label: "local.yaotong.logstore", qos: .utility)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Append a message at the given level (default `.info`).
    /// No-op when `isLogging` is `false`, so the user can mute the log
    /// from the debug panel without taking the app apart.
    func log(_ message: String, level: LogEntry.Level = .info) {
        guard isLogging else { return }
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        // Hop onto the writer queue so concurrent calls don't race; then
        // publish the change on the main thread for SwiftUI bindings.
        queue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                var next = self.entries
                next.append(entry)
                if next.count > Self.maxEntries {
                    next.removeFirst(next.count - Self.maxEntries)
                }
                self.entries = next
            }
        }
    }

    func clear() {
        entries = []
    }

    /// Convenience for human-friendly rendering in the log view.
    func formatted(_ entry: LogEntry) -> String {
        let time = formatter.string(from: entry.timestamp)
        return "\(time)  \(entry.level.symbol)  \(entry.message)"
    }
}
