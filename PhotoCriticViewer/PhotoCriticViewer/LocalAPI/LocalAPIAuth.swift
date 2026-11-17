import Foundation
import Security

/// Bearer-token auth for the local API. The token is generated once on first access and
/// persisted to ~/.photocritic/api_token (permissions 600) so it survives relaunches and a
/// client's saved copy keeps working -- it is never rotated automatically.
enum LocalAPIAuth {
    private static let dirURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".photocritic")
    static let tokenFileURL = dirURL.appendingPathComponent("api_token")

    static let token: String = loadOrCreate()

    static func isValid(_ presented: String) -> Bool {
        // Local, single-user tool -- a plain constant-time-ish comparison is enough; the
        // realistic threat model here is "wrong/missing token", not a timing side-channel
        // attacker who'd already need code execution on this same machine to measure it.
        presented == token
    }

    private static func loadOrCreate() -> String {
        if let existing = try? String(contentsOf: tokenFileURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let generated = generateToken()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? generated.write(to: tokenFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
        return generated
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // Falls back to a (much weaker) PRNG only in the astronomically unlikely case the
        // secure RNG is unavailable -- still local-only and token-gated either way, but worth
        // not silently handing out an all-zero token if SecRandomCopyBytes ever fails.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
