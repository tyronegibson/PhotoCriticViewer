import Foundation

/// Settings for the local control API, backed by UserDefaults so the Settings window's
/// toggle/fields and LocalAPIServer always see the same values without extra plumbing.
enum LocalAPISettings {
    private static let enabledKey = "localAPIEnabled"
    private static let portKey = "localAPIPort"
    private static let allowedRootsKey = "localAPIAllowedRoots"

    /// On by default once added -- an explicit opt-out via Settings, not an opt-in, since the
    /// server only ever binds to loopback and requires a bearer token for everything but
    /// GET /health, matching the risk of any other local-only, token-gated dev tool.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var port: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: portKey)
            return saved > 0 ? saved : 8765
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// Paths /open and /export are allowed to touch. Defaults to the active PhotoCritic
    /// workspace (the external drive holding the database, previews, and organized shoots)
    /// plus the known originals volume -- NOT the whole home folder, which is broader than
    /// this app ever needs to touch and was only ever a stand-in for "the real photo
    /// locations" (see LocalAPIPaths' doc comment for why a literal "home folder only" rule
    /// from the original spec didn't fit this app to begin with). Editable from Settings, e.g.
    /// to add another archive volume.
    static var allowedRoots: [String] {
        get {
            if let saved = UserDefaults.standard.array(forKey: allowedRootsKey) as? [String], !saved.isEmpty {
                return saved
            }
            return defaultRoots
        }
        set { UserDefaults.standard.set(newValue, forKey: allowedRootsKey) }
    }

    static var defaultRoots: [String] {
        [WorkspaceConfig.root.path, "/Volumes/ProfessionallyUnorganized"]
    }

    // MARK: - Remote (Tailscale) access -- V1.5 iPhone remote

    private static let remoteEnabledKey = "localAPIRemoteEnabled"
    private static let remoteAddressKey = "localAPIRemoteAddress"

    /// OFF by default. When on, the API is ALSO bound to `remoteAddress` (in addition to, never
    /// instead of, 127.0.0.1), same port, same bearer token. Turning it off closes that second
    /// listener and nothing else -- the full rollback for remote access.
    static var remoteEnabled: Bool {
        // bool(forKey:) rather than `as? Bool`: it also reads a "YES"/"1" string, which is what
        // a `-localAPIRemoteEnabled YES` launch argument arrives as. Absent = false.
        get { UserDefaults.standard.bool(forKey: remoteEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: remoteEnabledKey) }
    }

    static let defaultRemoteAddress = "100.100.10.20"

    /// This Mac's Tailscale IPv4 (`tailscale ip -4`). Must be inside Tailscale's 100.64.0.0/10
    /// range -- see isTailscaleAddress -- so this can never be pointed at a LAN or public interface.
    static var remoteAddress: String {
        get {
            let saved = UserDefaults.standard.string(forKey: remoteAddressKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return saved.isEmpty ? defaultRemoteAddress : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: remoteAddressKey) }
    }

    /// True only for a dotted-quad IPv4 in 100.64.0.0/10 (the CGNAT block Tailscale assigns
    /// from). Everything else -- 0.0.0.0, LAN 192.168.x/10.x, public IPs, hostnames, IPv6 -- is
    /// refused, which is what keeps "remote" meaning "tailnet only, never the open internet".
    static func isTailscaleAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value) else { return false }
            octets.append(value)
        }
        return octets[0] == 100 && (octets[1] & 0xC0) == 64
    }
}
