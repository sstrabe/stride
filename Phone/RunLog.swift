import Foundation

/// A per-run diagnostics log on the iPhone, in every recording mode: settings, events (start,
/// Watch mirroring, messages, Health results, the Watch's own report) and one row per second of
/// what Stride measured and clicked. Saved to Documents/diagnostics/run-*.json every 30 s and at
/// the end, so a crashed run still leaves most of it.
@MainActor
final class RunLog {
    private var url: URL?
    private var head: [String: Any] = [:]
    private var events: [[Any]] = []
    private var rows: [[Any]] = []
    private var start = Date()
    private var lastFlush = Date()

    static let columns = ["t", "click", "wanted", "stepLength", "measuredCadence", "speed", "distance",
                          "gpsGood", "gpsDistance", "pedoSteps", "pedoDistance", "heartRate", "holding", "hAcc", "alt",
                          "gpsPathDistance", "watchDistance", "watchSteps", "source"]

    func begin(_ info: [String: Any]) {
        start = Date()
        url = Export.directory.appending(path: "run-\(Int(start.timeIntervalSince1970)).json")
        head = info.merging(["started": Export.iso(start), "columns": Self.columns]) { a, _ in a }
        events = []; rows = []
        event("begin")
        flush()
    }

    var active: Bool { url != nil }

    func event(_ text: String) {
        guard url != nil else { return }
        events.append([Date().timeIntervalSince(start).rounded(toPlaces: 1), text])
    }

    func row(_ values: [Any?]) {
        guard url != nil else { return }
        rows.append([Date().timeIntervalSince(start).rounded(toPlaces: 1)] + values.map { $0 ?? NSNull() })
        if Date().timeIntervalSince(lastFlush) >= 30 { flush() }
    }

    func end(_ info: [String: Any]) {
        guard url != nil else { return }
        head.merge(info) { _, b in b }
        head["ended"] = Export.iso(Date())
        event("end")
        flush()
        url = nil
    }

    private func flush() {
        guard let url else { return }
        lastFlush = Date()
        var root = head
        root["events"] = events
        root["rows"] = rows
        if let d = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) { try? d.write(to: url) }
    }

    nonisolated static func list() -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: Export.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("run-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
