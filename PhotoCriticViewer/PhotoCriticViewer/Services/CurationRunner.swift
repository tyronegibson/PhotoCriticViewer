import Foundation
import Observation

/// Runs curate.py for delete/composite-set actions — same "Python is the sole
/// DB writer" pattern as IngestRunner, but these finish in well under a
/// second, so output is captured whole rather than live-streamed.
@MainActor
@Observable
final class CurationRunner {
    // Shared with IngestRunner.shared for the same reason: the local control API drives
    // curation/export actions through this exact instance rather than a second one.
    static let shared = CurationRunner()

    struct ActionResult {
        let success: Bool
        let output: String
    }

    private(set) var isRunning = false
    private var completionCallback: ((ActionResult) -> Void)?

    private static var projectRoot: URL { WorkspaceConfig.projectRoot }
    private static var pythonBinary: URL { WorkspaceConfig.pythonBinary }
    private static var scriptPath: URL { projectRoot.appendingPathComponent("curate.py") }
    private static var exportScriptPath: URL { projectRoot.appendingPathComponent("export_photo.py") }

    func deleteFile(fileId: Int64, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["delete-file", "--file", String(fileId)], completion: completion)
    }

    func deleteShoot(shootId: Int64, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["delete-shoot", "--shoot", String(shootId)], completion: completion)
    }

    func setComposite(groupId: Int64, on: Bool, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["set-composite", "--group", String(groupId), on ? "--on" : "--off"], completion: completion)
    }

    func renameShoot(shootId: Int64, newName: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["rename-shoot", "--shoot", String(shootId), "--name", newName], completion: completion)
    }

    func removeFromGroup(groupId: Int64, fileId: Int64, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["split-group", "--group", String(groupId), "--file", String(fileId)], completion: completion)
    }

    func markLook(fileId: Int64, name: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["mark-look", "--file", String(fileId), "--name", name], completion: completion)
    }

    func renameLook(lookId: Int64, name: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["rename-look", "--look", String(lookId), "--name", name], completion: completion)
    }

    func deleteLook(lookId: Int64, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["delete-look", "--look", String(lookId)], completion: completion)
    }

    func setSeparatePeople(shootId: Int64, on: Bool, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["set-separate-people", "--shoot", String(shootId), on ? "--on" : "--off"], completion: completion)
    }

    func markPerson(fileId: Int64, name: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["mark-person", "--file", String(fileId), "--name", name], completion: completion)
    }

    func renamePerson(personId: Int64, name: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["rename-person", "--person", String(personId), "--name", name], completion: completion)
    }

    func deletePerson(personId: Int64, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["delete-person", "--person", String(personId)], completion: completion)
    }

    /// The local API's POST /posted (posting-workflow tracking, not evaluation).
    func markPosted(fileId: Int64, platform: String, completion: @escaping (ActionResult) -> Void) {
        run(scriptPath: Self.scriptPath, arguments: ["mark-posted", "--file", String(fileId), "--platform", platform], completion: completion)
    }

    /// Decodes photos to full-resolution JPEG intermediates via export_photo.py (RAW decode +
    /// EXIF copy/GPS-strip, the only parts that need Python/rawpy). The actual crop/resize/
    /// color-space/watermark finishing happens in Swift afterward (LocalAPIExportProcessor),
    /// since subject-aware cropping needs Apple's Vision framework, which this project's
    /// Python side has no equivalent for.
    func decodeExportIntermediates(
        fileIds: [Int64], outDir: URL, keepGPS: Bool, completion: @escaping (ActionResult) -> Void
    ) {
        var arguments = ["--file"] + fileIds.map(String.init) + ["--out-dir", outDir.path]
        if keepGPS { arguments.append("--keep-gps") }
        run(scriptPath: Self.exportScriptPath, arguments: arguments, completion: completion)
    }

    private func run(scriptPath: URL, arguments: [String], completion: @escaping (ActionResult) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        completionCallback = completion

        let process = Process()
        process.executableURL = Self.pythonBinary
        process.arguments = [scriptPath.path] + arguments
        process.currentDirectoryURL = Self.projectRoot

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = env["PATH"].map { "\(extraPaths):\($0)" } ?? extraPaths
        env["PHOTOCRITIC_WORKSPACE"] = WorkspaceConfig.root.path
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let success = proc.terminationStatus == 0
            Task { @MainActor in
                self?.isRunning = false
                self?.completionCallback?(ActionResult(success: success, output: output))
                self?.completionCallback = nil
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            completionCallback = nil
            completion(ActionResult(success: false, output: "Failed to launch: \(error.localizedDescription)"))
        }
    }
}
