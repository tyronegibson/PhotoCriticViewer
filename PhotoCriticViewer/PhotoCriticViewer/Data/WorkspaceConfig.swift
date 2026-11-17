import Foundation

/// Mirrors photocritic/config.py's workspace paths. Overridable at runtime via
/// Settings (stored in UserDefaults) in case the fast drive's mount point changes.
enum WorkspaceConfig {
    private static let defaultRoot = "/Volumes/AI-/PhotoCritic"
    private static let rootDefaultsKey = "workspaceRootPath"

    static var root: URL {
        if let saved = UserDefaults.standard.string(forKey: rootDefaultsKey), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return URL(fileURLWithPath: defaultRoot)
    }

    /// Where the PhotoCritic Python project (organize.py, curate.py, .venv) lives. Defaults to
    /// ~/Developer/PhotoCritic; a second machine can override it with
    /// `defaults write com.photocritic.viewer projectRootPath <path>`.
    static var projectRoot: URL {
        if let saved = UserDefaults.standard.string(forKey: "projectRootPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Developer/PhotoCritic")
    }

    static var pythonBinary: URL {
        projectRoot.appendingPathComponent(".venv/bin/python3")
    }

    static func setRoot(_ path: String) {
        UserDefaults.standard.set(path, forKey: rootDefaultsKey)
    }

    static var databasePath: URL {
        root.appendingPathComponent("database/photocritic.db")
    }

    static var previewsDir: URL {
        root.appendingPathComponent("previews")
    }

    /// Mirrors config.py's HF_HOME (`WORKSPACE_ROOT/models/hf-cache`) — used
    /// when launching the ingest pipeline so it finds the already-downloaded
    /// model instead of redownloading to the default HF cache location.
    static var hfCacheDir: URL {
        root.appendingPathComponent("models/hf-cache")
    }

    /// Mirrors config.py's LOGS_DIR — where IngestRunner redirects a launched
    /// organize.py/evaluate.py subprocess's output, so it survives this app
    /// quitting mid-run instead of dying on a broken pipe.
    static var logsDir: URL {
        root.appendingPathComponent("logs")
    }

    static func previewURL(forPreviewPath path: String) -> URL {
        let filename = (path as NSString).lastPathComponent
        return previewsDir.appendingPathComponent(filename)
    }

    /// A flat JSON array of filenames (e.g. written by an ad-hoc phash-match
    /// lookup) that the dashboard grid highlights in orange wherever they
    /// appear, regardless of shoot. Optional — missing/invalid file just
    /// means nothing is highlighted.
    static var highlightsPath: URL {
        root.appendingPathComponent("highlighted_filenames.json")
    }

    static func loadHighlightedFilenames() -> Set<String> {
        guard let data = try? Data(contentsOf: highlightsPath),
              let names = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(names)
    }
}
