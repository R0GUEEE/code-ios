import Foundation

/// Launch breadcrumbs plus a crash recorder.
///
/// The app cannot be debugged on the machine that builds it, so it has to testify
/// about its own death: every boot step is appended to `Documents/launch.log`, a
/// marker file is written before the workbench is created and removed once the page
/// loads, and uncaught exceptions / fatal signals append a final line.
///
/// Next launch: marker still present ⇒ the previous run died somewhere between the
/// two breadcrumbs around it, and the UI shows the log instead of a blank screen.
enum Diagnostics {
    static let markerName = ".launch-in-progress"
    static let logName = "launch.log"

    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())

    static var logURL: URL { documents.appendingPathComponent(logName) }
    static var markerURL: URL { documents.appendingPathComponent(markerName) }
    static var crashReportsURL: URL { documents.appendingPathComponent("crashes") }

    private static let lock = NSLock()
    private static var installed = false
    private static var started = false
    private(set) static var crashedLastLaunch = false

    // MARK: - lifecycle

    /// Idempotent: called from App.init (earliest possible) and again from the view,
    /// whichever runs first wins.
    static func beginLaunch() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        installHandlers()

        crashedLastLaunch = FileManager.default.fileExists(atPath: markerURL.path)
        if crashedLastLaunch {
            append("=== previous launch did not finish booting ===")
        } else {
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
        }
        append("boot: start (previousCrash=\(crashedLastLaunch))")

        // arm the watchdog *before* anything that can trap
        try? "in progress\n".write(to: markerURL, atomically: true, encoding: .utf8)
    }

    static var previousLaunchCrashed: Bool { crashedLastLaunch }

    static func markBootCompleted(_ note: String) {
        append("boot: completed (\(note))")
        try? FileManager.default.removeItem(at: markerURL)
    }

    static func clearDiagnostics() {
        try? FileManager.default.removeItem(at: markerURL)
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - logging

    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(stamp)] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
        NSLog("codeios: \(line)")
    }

    static func log() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
    }

    // MARK: - crash capture

    private static func installHandlers() {
        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler { exception in
            let text = "CRASH (exception): \(exception.name.rawValue) — \(exception.reason ?? "-")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            Diagnostics.append(text)

            let report = documents.appendingPathComponent("crashes")
            try? FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
            let file = report.appendingPathComponent("exception-\(Int(Date().timeIntervalSince1970)).log")
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }

        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP] {
            signal(sig) { _ in
                // Signal context: no allocation, no locks — only write(2).
                Diagnostics.appendRaw("CRASH (signal)\n")
                _exit(128 + received)
            }
        }
    }

    /// Small, allocation-free append used from a signal handler.
    static func appendRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let path = logURL.path
        path.withCString { pointer in
            let fd = open(pointer, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
                _ = close(fd)
            }
        }
    }
}
