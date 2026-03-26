import AppKit
import Foundation

final class AppLogger: @unchecked Sendable {
    enum Level: String {
        case info = "INFO"
        case error = "ERROR"
    }

    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.fastconnect.logger", qos: .utility)
    private let fileManager = FileManager.default
    private let logsDirectory: URL

    private init() {
        let libraryLogsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("FastConnect", isDirectory: true)

        logsDirectory = libraryLogsURL
        ensureLogsDirectoryExists()
    }

    var logsDirectoryURL: URL {
        logsDirectory
    }

    func info(_ category: String, _ message: String) {
        log(level: .info, category: category, message: message)
    }

    func error(_ category: String, _ message: String) {
        log(level: .error, category: category, message: message)
    }

    func openLogsDirectoryInFinder() throws {
        try createLogsDirectoryIfNeeded()
        NSWorkspace.shared.open(logsDirectory)
    }

    func openCurrentLogFileInDefaultApp() throws {
        try createLogsDirectoryIfNeeded()

        let fileURL = currentLogFileURL()
        if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }

        NSWorkspace.shared.open(fileURL)
    }

    func currentLogFileURL() -> URL {
        logFileURL(for: Date())
    }

    private func log(level: Level, category: String, message: String) {
        queue.async {
            do {
                try self.createLogsDirectoryIfNeeded()

                let now = Date()
                let line = "[\(self.timestampString(from: now))] [\(level.rawValue)] [\(category)] \(message)\n"
                let logFileURL = self.logFileURL(for: now)
                let data = Data(line.utf8)

                if self.fileManager.fileExists(atPath: logFileURL.path) {
                    let handle = try FileHandle(forWritingTo: logFileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: logFileURL, options: .atomic)
                }
            } catch {
                NSLog("FastConnect logger error: %@", error.localizedDescription)
            }
        }
    }

    private func logFileURL(for date: Date) -> URL {
        logsDirectory.appendingPathComponent("\(dayString(from: date)).log")
    }

    private func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func timestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return formatter.string(from: date)
    }

    private func ensureLogsDirectoryExists() {
        queue.async {
            try? self.createLogsDirectoryIfNeeded()
        }
    }

    private func createLogsDirectoryIfNeeded() throws {
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
