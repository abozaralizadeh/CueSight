import Foundation

/// A text log with a size cap. When it fills up, the oldest lines go first.
/// It holds events and numbers only, never images.
public final class CappedLog: @unchecked Sendable {
    public let fileURL: URL
    public let maxBytes: Int
    private let lock = NSLock()
    private let clock: @Sendable () -> Date

    public init(fileURL: URL, maxBytes: Int = 5 * 1024 * 1024, clock: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.clock = clock
    }

    public func write(_ message: String, level: String = "info") {
        let stamp = ISO8601DateFormatter().string(from: clock())
        let line = "\(stamp) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try append(data)
            try trimIfNeeded()
        } catch {
            // The log must never break the app, so a failed write is dropped.
        }
    }

    public func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func trimIfNeeded() throws {
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        // Cut to three quarters, so a full log doesn't get rewritten on every line.
        let data = try Data(contentsOf: fileURL)
        var start = data.count - maxBytes * 3 / 4
        while start < data.count, data[start] != UInt8(ascii: "\n") { start += 1 }
        let kept = start < data.count ? data[(start + 1)...] : Data()
        try Data(kept).write(to: fileURL, options: .atomic)
    }
}
