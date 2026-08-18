import AppKit
import ArgumentParser
import Foundation

/// Manage quill's LaunchAgent so the daemon starts at login.
///
/// The binary ships alone, but install self-assembles a minimal
/// ~/Applications/Quill.app around a copy of it (Info.plist, feather .icns,
/// codesigned) and points the LaunchAgent inside. The bundle is what lets
/// macOS show a real icon on notifications and in System Settings, and gives
/// TCC a stable identity. The CLI copy stays wherever it was for doctor/dev
/// use — the bundle is regenerated from it on every install.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register quill to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    private static let label = "com.digimata.quill"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func writeAgent() throws {
        let binary = try assembleAppBundle(from: resolveBinaryPath())

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/quill.out.log",
            "StandardErrorPath": "/tmp/quill.err.log",
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // bootout fails while the daemon is busy, which then fails bootstrap
        // and silently leaves the *previous* build running — an install that
        // reports success but changes nothing. kickstart -k is the reliable
        // restart, so it's the one that matters here.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        _ = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        let restart = runLaunchctl(["kickstart", "-k", "gui/\(uid())/\(Self.label)"])
        if restart.status != 0 {
            let warning = "warning: couldn't restart the agent (\(restart.status)): "
                + "\(restart.stderr) — the new build starts at next login\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   /tmp/quill.out.log, /tmp/quill.err.log")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
    }

    /// Build ~/Applications/Quill.app around a copy of `binary`. Returns the
    /// bundled executable's path (what the LaunchAgent should run).
    private func assembleAppBundle(from binary: String) throws -> String {
        let fm = FileManager.default
        let bundle = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Quill.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try? fm.removeItem(at: bundle)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        try fm.copyItem(
            at: URL(fileURLWithPath: binary),
            to: macos.appendingPathComponent("quill")
        )

        // Reuse the usage strings from the binary's embedded plist so they
        // live in one place (Sources/quill/Info.plist).
        let embedded = Bundle.main.infoDictionary ?? [:]
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.digimata.quill",
            "CFBundleName": "Quill",
            "CFBundleExecutable": "quill",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleIconFile": "quill",
            "LSUIElement": true,
            "LSMinimumSystemVersion": "15.0",
        ]
        for key in ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription"] {
            info[key] = embedded[key] ?? "quill records meetings locally."
        }
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))

        try writeIcns(to: resources.appendingPathComponent("quill.icns"))
        try sign(bundle)

        print("✓ assembled \(bundle.path)")
        return macos.appendingPathComponent("quill").path
    }

    /// Rasterize the feather tile into an .iconset and let iconutil pack it.
    private func writeIcns(to url: URL) throws {
        let fm = FileManager.default
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("quill-\(getpid()).iconset", isDirectory: true)
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let png = Feather.iconPNG(pixels: size * scale) else { continue }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(
                    to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }

        let task = Process()
        task.launchPath = "/usr/bin/iconutil"
        task.arguments = ["-c", "icns", "-o", url.path, iconset.path]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "warning: iconutil exited \(task.terminationStatus) — bundle gets no icon\n".utf8
            ))
        }
    }

    /// Sign with the first Apple Development identity so TCC grants survive
    /// rebuilds; ad-hoc as a last resort (grants then reset per build).
    private func sign(_ bundle: URL) throws {
        let list = Process()
        list.launchPath = "/usr/bin/security"
        list.arguments = ["find-identity", "-v", "-p", "codesigning"]
        let pipe = Pipe()
        list.standardOutput = pipe
        try? list.run()
        list.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let identity = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: "\"")
                guard parts.count >= 2, parts[1].hasPrefix("Apple Development") else {
                    return nil
                }
                return String(parts[1])
            }
            .first ?? "-"
        if identity == "-" {
            FileHandle.standardError.write(Data(
                "note: no Apple Development identity — ad-hoc signing (permission prompts will repeat after rebuilds)\n"
                    .utf8
            ))
        }

        let task = Process()
        task.launchPath = "/usr/bin/codesign"
        task.arguments = ["--force", "--sign", identity, bundle.path]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "warning: codesign exited \(task.terminationStatus)\n".utf8
            ))
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/quill is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/quill"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "quill"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/quill not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the quill binary. install it to /usr/local/bin/quill first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
