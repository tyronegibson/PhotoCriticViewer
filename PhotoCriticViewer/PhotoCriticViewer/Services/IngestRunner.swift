import Foundation
import Observation
import UserNotifications

/// Launches organize.py (fast, CPU-only — sorts a folder into per-date
/// shoots) or evaluate.py (slow, GPU — scores one shoot) as a subprocess.
/// The Swift app still never writes to the database itself — Python remains
/// the sole writer.
///
/// Output is redirected to a log FILE, not a Pipe. A Pipe's read end closes
/// when this app quits, and the next line the child process tries to print
/// raises SIGPIPE and kills it — even though the OS reparents it to launchd
/// and it looks like it's still running. Learned this the hard way: rebuilding
/// the app mid-ingest silently killed a job 90+ minutes in. A log file has no
/// such dependency on this process being alive.
///
/// @MainActor-isolated so it's implicitly Sendable, letting `self` be captured
/// safely from Process's @Sendable terminationHandler closure (which fires on
/// an arbitrary background thread).
@MainActor
@Observable
final class IngestRunner {
    // A single shared instance rather than one per owning view: the local control API
    // (LocalAPIServer) triggers organize.py/evaluate.py through this exact same instance,
    // not a second one of its own, so an API-triggered job shows live in the UI's Ingest
    // Log sheet and the "only one job at a time" guard below applies across both.
    static let shared = IngestRunner()

    enum Status: Equatable {
        case idle
        case running(label: String)
        case finished(label: String, success: Bool)
    }

    private(set) var status: Status = .idle
    private(set) var log: String = ""
    /// Parsed from "PROGRESS <stage>: <current>/<total>" lines the pipeline
    /// prints (see pipeline.py) — a real percentage independent of tqdm's
    /// terminal-only bar rendering, which is unreadable in a redirected log.
    private(set) var progressStage: String?
    private(set) var progressCurrent: Int?
    private(set) var progressTotal: Int?

    var progressFraction: Double? {
        guard let progressCurrent, let progressTotal, progressTotal > 0 else { return nil }
        return Double(progressCurrent) / Double(progressTotal)
    }

    private var process: Process?
    // Stored rather than captured directly by the @Sendable terminationHandler
    // closure below — a plain `() -> Void` isn't Sendable, but reading it back
    // off `self` from inside an already-@MainActor Task is.
    private var onFinishedCallback: (() -> Void)?
    private var tailTimer: Timer?
    private var logFileURL: URL?
    private var lastReadOffset: UInt64 = 0

    private static var projectRoot: URL { WorkspaceConfig.projectRoot }
    private static var pythonBinary: URL { WorkspaceConfig.pythonBinary }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    // A plain UNUserNotificationCenterDelegate is needed just to show the
    // banner+sound even while the app is frontmost (the system default is
    // to suppress it then, on the assumption you're already looking at the
    // app — not a safe assumption for the Log sheet sitting open).
    private static let notificationPresenter = NotificationPresenter()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationPresenter
        // Alert + sound so a finished (or failed) organize/evaluate job —
        // these can run for hours — gets noticed even if the app isn't in
        // the foreground. Silently ignored if the user declines.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyFinished(label: String, success: Bool) {
        let content = UNMutableNotificationContent()
        content.title = success ? "PhotoCritic — Done" : "PhotoCritic — Failed"
        content.body = label
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Phase 1 — fast, CPU-only: sorts `folder` into per-date shoots.
    func startOrganize(folder: URL, onFinished: @escaping () -> Void) {
        start(
            label: "Organizing \(folder.lastPathComponent)",
            arguments: [Self.projectRoot.appendingPathComponent("organize.py").path, folder.path],
            logName: "organize",
            onFinished: onFinished
        )
    }

    /// Phase 2 — slow, GPU: scores one already-organized shoot.
    func startEvaluate(shootId: Int64, shootLabel: String, onFinished: @escaping () -> Void) {
        start(
            label: "Evaluating \(shootLabel)",
            arguments: [Self.projectRoot.appendingPathComponent("evaluate.py").path, "--shoot", String(shootId)],
            logName: "evaluate-shoot-\(shootId)",
            onFinished: onFinished
        )
    }

    /// The local API's POST /critique with specific ids: scores ONLY these files, not their
    /// whole shoot(s) (see evaluate.py --files / pipeline.evaluate_specific_files).
    func startEvaluateFiles(fileIds: [Int64], label: String, onFinished: @escaping () -> Void) {
        start(
            label: label,
            arguments: [Self.projectRoot.appendingPathComponent("evaluate.py").path, "--files"] + fileIds.map(String.init),
            logName: "evaluate-files-\(fileIds.count)",
            onFinished: onFinished
        )
    }

    private func start(label: String, arguments: [String], logName: String, onFinished: @escaping () -> Void) {
        guard !isRunning else { return }
        onFinishedCallback = onFinished
        log = ""
        lastReadOffset = 0
        progressStage = nil
        progressCurrent = nil
        progressTotal = nil
        status = .running(label: label)

        let logsDir = WorkspaceConfig.logsDir
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = logsDir.appendingPathComponent("\(logName)-\(stamp).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        logFileURL = logFile

        guard let outputHandle = try? FileHandle(forWritingTo: logFile) else {
            status = .finished(label: label, success: false)
            log = "Failed to open log file at \(logFile.path)\n"
            return
        }

        let process = Process()
        // Wrapped in caffeinate: evaluation alone can run 30+ minutes, and a
        // display/idle sleep mid-run can yank the GPU context out from under
        // MLX's Metal command buffers (seen as "kIOGPUCommandBufferCallback
        // ErrorInnocentVictim" — the run gets killed, not just paused).
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dimsu", Self.pythonBinary.path] + arguments
        process.currentDirectoryURL = Self.projectRoot

        // GUI apps don't inherit a login shell's PATH, so exiftool (Homebrew)
        // and the model's HF_HOME (must match config.py's derivation, or the
        // pipeline redownloads the 33.5GB model to the wrong cache) both need
        // to be set explicitly here rather than relying on `source .venv/bin/activate`.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        env["HF_HOME"] = WorkspaceConfig.hfCacheDir.path
        env["PHOTOCRITIC_WORKSPACE"] = WorkspaceConfig.root.path
        // Python fully buffers stdout (rather than line-buffering) once it's
        // not a TTY — i.e. always, here, since it's redirected to a log file.
        // Without this, print()/tqdm output just accumulates invisibly until
        // the buffer flushes or the process exits, making the live "Log…"
        // view show nothing for long stretches then dump it all at once.
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        process.standardOutput = outputHandle
        process.standardError = outputHandle

        process.terminationHandler = { [weak self] proc in
            try? outputHandle.close()
            let success = proc.terminationStatus == 0
            Task { @MainActor in
                self?.stopTailing()
                self?.refreshLogFromDisk()
                self?.status = .finished(label: label, success: success)
                self?.process = nil
                self?.notifyFinished(label: label, success: success)
                self?.onFinishedCallback?()
                self?.onFinishedCallback = nil
            }
        }

        do {
            try process.run()
            self.process = process
            startTailing()
        } catch {
            try? outputHandle.close()
            status = .finished(label: label, success: false)
            log = "Failed to launch: \(error.localizedDescription)\n"
            notifyFinished(label: label, success: false)
        }
    }

    private func startTailing() {
        tailTimer?.invalidate()
        tailTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLogFromDisk() }
        }
    }

    private func stopTailing() {
        tailTimer?.invalidate()
        tailTimer = nil
    }

    /// Reads only the bytes appended since the last tick — the file can grow
    /// large over an hours-long run, so re-reading it whole every second
    /// would waste real IO/CPU.
    private func refreshLogFromDisk() {
        guard let logFileURL, let handle = try? FileHandle(forReadingFrom: logFileURL) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: lastReadOffset)) != nil else { return }
        let newData = handle.readDataToEndOfFile()
        guard !newData.isEmpty, let newText = String(data: newData, encoding: .utf8) else { return }
        lastReadOffset += UInt64(newData.count)
        appendLog(newText)
    }

    private func appendLog(_ text: String) {
        log += text
        // Cap retained output so an hours-long run doesn't grow this unbounded.
        if log.utf8.count > 300_000 {
            log = String(log.suffix(250_000))
        }
        updateProgress(fromNewText: text)
    }

    /// Only scans the newly-appended chunk (not the whole accumulated log)
    /// for the last PROGRESS marker — cheap even over an hours-long run.
    private func updateProgress(fromNewText text: String) {
        guard let match = text.matches(of: Self.progressRegex).last else { return }
        guard let current = Int(match.output.2), let total = Int(match.output.3) else { return }
        progressStage = String(match.output.1)
        progressCurrent = current
        progressTotal = total
    }

    private static let progressRegex = /PROGRESS ([\w+]+): (\d+)\/(\d+)/

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
