import Foundation
import SwiftUI

protocol TBLogEvent: Encodable {
    var type: String { get }
    var timestamp: Date { get }
}

class TBLogEventAppStart: TBLogEvent {
    internal let type = "appstart"
    internal let timestamp: Date = Date()
}

class TBLogEventTransition: TBLogEvent {
    internal let type = "transition"
    internal let timestamp: Date = Date()

    private let event: String
    private let fromState: String
    private let toState: String

    init(fromContext ctx: TBStateMachine.Context) {
        event = "\(ctx.event!)"
        fromState = "\(ctx.fromState)"
        toState = "\(ctx.toState)"
    }
}

private let logFileName = "TomatoBar.log"
private let lineEnd = "\n".data(using: .utf8)!

/// Project-local sessions log folder. Personal build, hardcoded path on purpose.
internal let sessionsLogsURL = URL(
    fileURLWithPath: "/Users/abraham/Desktop/Sandbox/tomato-timer-custom/logs",
    isDirectory: true
)

internal let logger = TBLogger()
internal let sessionsLogger = TBSessionsLogger()

struct TBCompletedSession: Codable, Identifiable {
    let id: UUID
    let index: Int
    let start: Date
    let end: Date

    init(index: Int, start: Date, end: Date) {
        self.id = UUID()
        self.index = index
        self.start = start
        self.end = end
    }
}

/// Reads the full persisted sessions history back from disk for the Stats dashboard.
/// Read-only; never mutates the log. Returns [] on any error so the UI degrades gracefully.
enum TBSessionsReader {
    static func loadAll() -> [TBCompletedSession] {
        let fileURL = sessionsLogsURL.appendingPathComponent("sessions.jsonl")
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [TBCompletedSession] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let session = try? decoder.decode(TBCompletedSession.self, from: lineData) else {
                continue
            }
            result.append(session)
        }
        return result
    }
}

class TBSessionsLogger {
    private let encoder = JSONEncoder()
    private let fileURL: URL?

    init() {
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: sessionsLogsURL,
                                            withIntermediateDirectories: true)
        } catch {
            NSLog("TBSessionsLogger: cannot create sessions folder: \(error)")
            fileURL = nil
            return
        }
        fileURL = sessionsLogsURL.appendingPathComponent("sessions.jsonl")
    }

    func append(session: TBCompletedSession) {
        guard let fileURL = fileURL else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        do {
            let jsonData = try encoder.encode(session)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: jsonData + lineEnd)
            try handle.synchronize()
        } catch {
            print("cannot write session log: \(error)")
        }
    }
}

class TBLogger {
    private let logHandle: FileHandle?
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970

        let fileManager = FileManager.default
        let logPath = fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent(logFileName)
            .path

        if !fileManager.fileExists(atPath: logPath) {
            guard fileManager.createFile(atPath: logPath, contents: nil) else {
                print("cannot create log file")
                logHandle = nil
                return
            }
        }

        logHandle = FileHandle(forUpdatingAtPath: logPath)
        guard logHandle != nil else {
            print("cannot open log file")
            return
        }
    }

    func append(event: TBLogEvent) {
        guard let logHandle = logHandle else {
            return
        }
        do {
            let jsonData = try encoder.encode(event)
            try logHandle.seekToEnd()
            try logHandle.write(contentsOf: jsonData + lineEnd)
            try logHandle.synchronize()
        } catch {
            print("cannot write to log file: \(error)")
        }
    }
}
