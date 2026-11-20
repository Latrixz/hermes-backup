import AppKit
import Foundation

/// Everything this app knows about Hermes. The archive itself is Hermes' own
/// `hermes backup` / `hermes import`, which snapshot SQLite safely and skip the codebase —
/// this app never copies ~/.hermes by hand.
enum Hermes {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dataFolder = home.appendingPathComponent(".hermes")
    static let desktopBundleID = "com.nousresearch.hermes"
    /// The desktop app keeps chat images and its connection list outside ~/.hermes,
    /// so `hermes backup` misses them. We carry these alongside.
    static let desktopSupport = home.appendingPathComponent("Library/Application Support/Hermes")
    static let desktopExtras = ["composer-images", "connections.json"]

    static var cli: String? {
        let candidates = [home.appendingPathComponent(".local/bin/hermes").path,
                          dataFolder.appendingPathComponent("hermes-agent/.hermes/bin/hermes").path,
                          "/opt/homebrew/bin/hermes", "/usr/local/bin/hermes"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let r = try? Shell.run("/bin/zsh", ["-lc", "command -v hermes"], timeout: 20)
        let path = r?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var hasData: Bool {
        FileManager.default.fileExists(atPath: dataFolder.appendingPathComponent("config.yaml").path)
            || FileManager.default.fileExists(atPath: dataFolder.appendingPathComponent("state.db").path)
    }

    struct NotInstalled: LocalizedError {
        var errorDescription: String? { "Hermes isn't installed on this Mac." }
    }

    static func requireCLI() throws -> String {
        guard let cli else { throw NotInstalled() }
        return cli
    }

    static func version() -> String? {
        guard let cli, let r = try? Shell.run(cli, ["--version"], timeout: 60), r.ok else { return nil }
        return r.output.split(separator: "\n").first.map(String.init)
    }

    /// `hermes backup` into `zip`. Takes a couple of seconds for a typical install.
    static func backup(to zip: URL) throws {
        let r = try Shell.run(try requireCLI(), ["backup", "-o", zip.path, "-k", "0"])
        guard r.ok, FileManager.default.fileExists(atPath: zip.path) else {
            throw ShellError(message: "Hermes couldn't make a backup.\n\(r.tail)")
        }
    }

    static func restore(from zip: URL) throws {
        let r = try Shell.run(try requireCLI(), ["import", "--force", zip.path])
        guard r.ok else { throw ShellError(message: "Hermes couldn't restore the backup.\n\(r.tail)") }
    }

    static func stopGateway() {
        guard let cli else { return }
        _ = try? Shell.run(cli, ["gateway", "stop"], timeout: 60)
    }

    // MARK: Desktop app

    static var runningDesktopApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID).first
    }

    /// Asks the desktop app to quit and waits for it. Returns its location so it can be reopened.
    static func quitDesktopApp() throws -> URL? {
        guard let app = runningDesktopApp else { return nil }
        let url = app.bundleURL
        app.terminate()
        let deadline = Date().addingTimeInterval(30)
        while !app.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        guard app.isTerminated else {
            throw ShellError(message: "Hermes didn't close. Quit it yourself, then try again.")
        }
        return url
    }

    /// Hermes still running anywhere else (a chat in Terminal, a dashboard) would be
    /// writing to the files we're about to replace.
    static func otherRunningProcesses() -> [String] {
        guard let r = try? Shell.run("/usr/bin/pgrep", ["-fl", "\\.hermes/(hermes-agent|tools)/"], timeout: 20),
              r.ok else { return [] }
        return r.output.split(separator: "\n").map(String.init)
    }
}
