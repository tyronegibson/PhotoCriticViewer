import SwiftUI
import CoreImage.CIFilterBuiltins

/// The Settings scene (⌘,) for the local control API: on/off toggle, port, token location,
/// and the allowed-roots list /open and /export are restricted to.
struct SettingsView: View {
    @AppStorage("localAPIEnabled") private var enabled = true
    @AppStorage("localAPIPort") private var port = 8765
    @State private var allowedRootsText: String = LocalAPISettings.allowedRoots.joined(separator: "\n")
    @State private var copiedToken = false
    @AppStorage("localAPIRemoteEnabled") private var remoteEnabled = false
    @State private var remoteAddress: String = LocalAPISettings.remoteAddress
    @State private var detectMessage: String?
    @State private var showingSetupQR = false

    var body: some View {
        Form {
            Section("Local Control API") {
                Toggle("Enable local control API", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        if newValue {
                            LocalAPIServer.shared.start()
                        } else {
                            LocalAPIServer.shared.stop()
                        }
                    }
                    .help("Lets a local assistant drive the app over HTTP on 127.0.0.1. Reachable from other devices only if Remote Access below is turned on, and then only over Tailscale.")

                LabeledContent("Port") {
                    TextField("", value: $port, format: .number)
                        .frame(width: 80)
                        .onChange(of: port) { _, _ in
                            // Port changes need a restart to take effect -- rebind rather
                            // than leaving the old listener running on the previous port.
                            if enabled {
                                LocalAPIServer.shared.stop()
                                LocalAPIServer.shared.start()
                            }
                        }
                }

                LabeledContent("Token file") {
                    HStack {
                        Text(LocalAPIAuth.tokenFileURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(copiedToken ? "Copied" : "Copy Token") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LocalAPIAuth.token, forType: .string)
                            copiedToken = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedToken = false }
                        }
                    }
                }

                Text(LocalAPIServer.shared.isRunning ? "Running." : (enabled ? "Not running — \(LocalAPIServer.shared.lastError ?? "unknown reason")." : "Disabled."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remote Access (iPhone over Tailscale)") {
                Toggle("Also listen on this Mac's Tailscale address", isOn: $remoteEnabled)
                    .disabled(!enabled)
                    .onChange(of: remoteEnabled) { _, newValue in
                        if newValue {
                            LocalAPIServer.shared.startRemoteIfEnabled()
                        } else {
                            LocalAPIServer.shared.stopRemote()
                            showingSetupQR = false
                        }
                    }
                    .help("Adds a second listener on the Tailscale IP only, with the same token. 127.0.0.1 keeps working either way. Turn off to close it.")

                LabeledContent("Tailscale IP") {
                    HStack {
                        TextField("100.x.y.z", text: $remoteAddress)
                            .frame(width: 140)
                            .onSubmit(applyRemoteAddress)
                        Button("Detect", action: detectTailscaleAddress)
                        Button("Apply", action: applyRemoteAddress)
                            .disabled(remoteAddress == LocalAPISettings.remoteAddress)
                    }
                }
                if let detectMessage {
                    Text(detectMessage).font(.caption).foregroundStyle(.secondary)
                }

                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text(remoteStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if remoteEnabled && enabled {
                    Button(showingSetupQR ? "Hide iPhone setup QR" : "Show iPhone setup QR") {
                        showingSetupQR.toggle()
                    }
                    if showingSetupQR, let image = Self.qrImage(for: remoteSetupURL) {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 200, height: 200)
                            Text("Scan with the iPhone Camera (the phone must be on Tailscale). This QR contains the API token — don't screenshot or share it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Allowed Paths") {
                Text("POST /open and /export only accept paths inside one of these folders, one per line. Defaults to your home folder and the PhotoCritic workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $allowedRootsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .onChange(of: allowedRootsText) { _, newValue in
                        let roots = newValue.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        LocalAPISettings.allowedRoots = roots.isEmpty ? LocalAPISettings.defaultRoots : roots
                    }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var remoteStatusText: String {
        guard enabled else { return "The control API is off, so remote access is off too." }
        guard remoteEnabled else { return "Off — the API is reachable from this Mac only." }
        let server = LocalAPIServer.shared
        if server.isRemoteRunning {
            return "Listening on http://\(LocalAPISettings.remoteAddress):\(LocalAPISettings.port)/ — open it on the iPhone."
        }
        return "Not listening — \(server.remoteError ?? "starting…")"
    }

    private var remoteSetupURL: String {
        "http://\(LocalAPISettings.remoteAddress):\(LocalAPISettings.port)/#token=\(LocalAPIAuth.token)"
    }

    private func applyRemoteAddress() {
        let trimmed = remoteAddress.trimmingCharacters(in: .whitespaces)
        guard LocalAPISettings.isTailscaleAddress(trimmed) else {
            detectMessage = "\(trimmed) isn't a Tailscale address (100.64.0.0/10)."
            return
        }
        remoteAddress = trimmed
        LocalAPISettings.remoteAddress = trimmed
        detectMessage = nil
        LocalAPIServer.shared.stopRemote()
        LocalAPIServer.shared.startRemoteIfEnabled()
    }

    /// Runs `tailscale ip -4` (the CLI install from tailscale.com puts it in /usr/local/bin;
    /// the App Store build ships it inside the app bundle).
    private func detectTailscaleAddress() {
        detectMessage = "Detecting…"
        Task.detached {
            let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                              "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            var found: String?
            for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["ip", "-4"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                guard (try? process.run()) != nil else { continue }
                process.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if let ip = out.split(whereSeparator: \.isNewline).map(String.init).first(where: LocalAPISettings.isTailscaleAddress) {
                    found = ip
                    break
                }
            }
            let result = found
            await MainActor.run {
                if let result {
                    remoteAddress = result
                    detectMessage = result == LocalAPISettings.remoteAddress ? "Detected \(result) (already in use)." : "Detected \(result) — press Apply."
                } else {
                    detectMessage = "Couldn't read an address from the tailscale CLI. Is Tailscale running?"
                }
            }
        }
    }

    static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
