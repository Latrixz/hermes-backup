import AppKit

/// Updates come straight from this project's GitHub Releases: the newest release's `.dmg` is
/// downloaded, the app inside is checked (signed by the same Apple team, newer version), and it
/// replaces this copy, then relaunches. Nothing installs without the user clicking Install.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    nonisolated static let repo = "Latrixz/hermes-backup"
    /// Every release must be signed by this Apple Developer team, whatever this copy is signed with.
    nonisolated static let teamID = "ZT64LKJB82"

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmg: URL
        let page: URL
    }

    enum Phase: Equatable { case idle, checking, downloading, installing }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    private var timer: Timer?

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        Task { await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(manual: false) }
        }
    }

    /// `manual`: the user asked, so say something either way.
    func check(manual: Bool) async {
        guard phase == .idle else { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        do {
            let latest = try await Self.fetchLatest()
            if let latest, Self.isNewer(latest.version, than: Self.currentVersion) {
                available = latest
                if manual { offer(latest) }
            } else {
                available = nil
                if manual { inform("Hermes Backup is up to date", "You have the newest version, \(Self.currentVersion).") }
            }
        } catch {
            if manual { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Asks before installing; called from the menu row or after a manual check.
    func offer(_ r: Release? = nil) {
        guard let r = r ?? available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Hermes Backup \(r.version) is available"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "You have \(Self.currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(800)))
            + "\n\nIt installs in a few seconds and reopens. Your settings, password and backups stay as they are."
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Release Notes")
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(r) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    func install(_ r: Release) async {
        guard phase == .idle else { return }
        if AppModel.shared.activity != nil {
            inform("Try again in a moment", "A backup or restore is running. Install the update once it finishes.")
            return
        }
        let target = Bundle.main.bundleURL
        phase = .downloading
        do {
            let staged = try await Self.download(r)
            phase = .installing
            try await Task.detached { try Self.replace(target, with: staged, relaunch: true) }.value
            NSApp.terminate(nil)
        } catch {
            phase = .idle
            let a = NSAlert()
            a.messageText = "The update didn't install"
            a.informativeText = error.localizedDescription + "\n\nYou can download it from GitHub and drag it into Applications instead."
            a.addButton(withTitle: "Open Download Page")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
        }
    }

    private func inform(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Steps (no UI; also used by the self-test)

    nonisolated static func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HermesBackup/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }   // no releases yet
        guard code == 200 else { throw ShellError(message: "GitHub answered \(code).") }
        return try parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Body: Decodable {
            let tag_name: String; let body: String?; let html_url: URL
            let draft: Bool?; let prerelease: Bool?; let assets: [Asset]
        }
        let b = try JSONDecoder().decode(Body.self, from: data)
        guard b.draft != true, b.prerelease != true,
              let dmg = b.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        let version = b.tag_name.hasPrefix("v") ? String(b.tag_name.dropFirst()) : b.tag_name
        return Release(version: version, notes: b.body ?? "", dmg: dmg.browser_download_url, page: b.html_url)
    }

    /// Numeric, part by part: 0.10.0 is newer than 0.9.2.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Downloads the DMG and copies the verified app out of it into a scratch folder.
    nonisolated static func download(_ r: Release) async throws -> URL {
        let (file, resp) = try await URLSession.shared.download(from: r.dmg)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShellError(message: "The download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return try await Task.detached { try unpack(file, expecting: r.version) }.value
    }

    nonisolated static func unpack(_ dmgFile: URL, expecting version: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("HermesBackupUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")
        try fm.moveItem(at: dmgFile, to: dmg)
        let mount = work.appendingPathComponent("mnt")
        let attach = try Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                                        "-noautoopen", "-mountpoint", mount.path])
        guard attach.ok else { throw ShellError(message: "Couldn't open the download.\n\(attach.tail)") }
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let src = mount.appendingPathComponent("Hermes Backup.app")
        let app = work.appendingPathComponent("Hermes Backup.app")
        guard fm.fileExists(atPath: src.path) else { throw ShellError(message: "The download doesn't contain Hermes Backup.") }
        let copy = try Shell.run("/usr/bin/ditto", [src.path, app.path])
        guard copy.ok else { throw ShellError(message: "Couldn't copy the update.\n\(copy.tail)") }
        try verify(app, expecting: version)
        return app
    }

    /// The app must be intact, signed by our team, and the version the release says it is.
    nonisolated static func verify(_ app: URL, expecting version: String) throws {
        let check = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.ok else { throw ShellError(message: "The update's signature is broken, so it wasn't installed.") }
        let info = try Shell.run("/usr/bin/codesign", ["-dv", app.path])
        guard info.output.contains("TeamIdentifier=\(teamID)") else {
            throw ShellError(message: "The update isn't signed by the Hermes Backup developer, so it wasn't installed.")
        }
        let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard plist?["CFBundleIdentifier"] as? String == "com.quantumape.hermesbackup",
              plist?["CFBundleShortVersionString"] as? String == version else {
            throw ShellError(message: "The download isn't the expected version, so it wasn't installed.")
        }
    }

    /// Swaps the app in place. With `relaunch`, a small helper waits for this app to quit, opens
    /// the new copy and cleans up; the caller then quits.
    nonisolated static func replace(_ target: URL, with staged: URL, relaunch: Bool) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw ShellError(message: "This Mac doesn't let Hermes Backup write to \(parent.path).")
        }
        // Copy next to the target first (same disk), then swap, so a failure never leaves no app.
        let incoming = parent.appendingPathComponent(".Hermes Backup update.app")
        try? fm.removeItem(at: incoming)
        let copy = try Shell.run("/usr/bin/ditto", [staged.path, incoming.path])
        guard copy.ok else { throw ShellError(message: "Couldn't copy the update.\n\(copy.tail)") }
        _ = try fm.replaceItemAt(target, withItemAt: incoming)
        try? fm.removeItem(at: staged.deletingLastPathComponent())

        guard relaunch else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        for i in 1 2 3 4 5; do /usr/bin/open "$1" && exit 0; sleep 1; done
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "relaunch", target.path]
        try p.run()   // keeps running after this app quits
    }
}
