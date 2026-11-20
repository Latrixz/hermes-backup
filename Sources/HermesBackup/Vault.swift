import Foundation

/// Backups are AES-256 encrypted disk images. That is deliberate: if this app is ever gone,
/// a backup still opens with a double-click and the password, on any Mac.
enum Vault {
    struct WrongPassword: LocalizedError {
        var errorDescription: String? { "That password doesn't open this backup." }
    }

    static func seal(folder: URL, to dmg: URL, password: String) throws {
        let r = try Shell.run("/usr/bin/hdiutil",
                              ["create", "-quiet", "-volname", "Hermes Backup", "-srcfolder", folder.path,
                               "-fs", "HFS+", "-format", "UDZO", "-encryption", "AES-256",
                               "-stdinpass", "-o", dmg.path],
                              stdin: Data(password.utf8))
        guard r.ok else { throw ShellError(message: "Couldn't lock the backup.\n\(r.tail)") }
    }

    /// Mounts read-only and hidden from Finder. Pair with `close`.
    static func open(_ dmg: URL, at mountPoint: URL, password: String) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let r = try Shell.run("/usr/bin/hdiutil",
                              ["attach", dmg.path, "-stdinpass", "-readonly", "-nobrowse",
                               "-noautoopen", "-noverify", "-mountpoint", mountPoint.path],
                              stdin: Data(password.utf8))
        if r.output.contains("Authentication error") { throw WrongPassword() }
        guard r.ok else { throw ShellError(message: "Couldn't open the backup.\n\(r.tail)") }
    }

    static func close(_ mountPoint: URL) {
        _ = try? Shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"], timeout: 60)
    }
}
