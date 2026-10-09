import Foundation

/// On-disk queue: a JSON Lines file plus an in-memory mirror.
/// Appends write a single line; removals rewrite the whole file. The queue is small
/// (capped at 2000 events by default), so the rewrite cost is negligible.
/// Only used from inside the `Engine` actor, so it needs no locking of its own.
final class EventQueue {
    private let fileURL: URL
    private let capacity: Int
    private(set) var events: [QueuedEvent] = []

    init(directory: URL, capacity: Int) {
        self.fileURL = directory.appendingPathComponent("queue.jsonl")
        self.capacity = capacity
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var count: Int { events.count }
    var isEmpty: Bool { events.isEmpty }

    func append(_ event: QueuedEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            rewrite()
            return
        }
        guard var line = try? JSONEncoder().encode(event) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    func peek(_ max: Int) -> [QueuedEvent] {
        Array(events.prefix(max))
    }

    /// Removes by id rather than by position: while a batch is in flight the head of the
    /// queue may have been dropped due to overflow, so positional removal could delete the wrong events.
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        events.removeAll { ids.contains($0.id) }
        rewrite()
    }

    func removeAll() {
        events.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // A crash may leave a partial last line: parse line by line and skip bad lines.
        events = data.split(separator: 0x0A).compactMap { try? decoder.decode(QueuedEvent.self, from: $0) }
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            rewrite()
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
