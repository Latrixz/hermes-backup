import AppKit
import Foundation

/// The blocking work. Every function here runs off the main thread.
enum Engine {
    typealias Progress = @Sendable (String) -> Void

    /// A scratch folder that only this user can read; the unlocked zip passes through it
    /// for a few seconds and is deleted with it.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesBackup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    // MARK: Backup

    /// Makes one locked backup file in a scratch folder. The caller copies it out, then
    /// deletes `work`.
    static func makeBackup(password: String, beforeRestore: Bool = false,
                           progress: Progress) throws -> (dmg: URL, work: URL) {
        let work = try scratch()
        do {
            let payload = work.appendingPathComponent("payload")
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)

            progress("Copying Hermes…")
            try Hermes.backup(to: payload.appendingPathComponent("hermes-backup.zip"))

            let extras = payload.appendingPathComponent("desktop")
            for name in Hermes.desktopExtras {
                let src = Hermes.desktopSupport.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                try FileManager.default.createDirectory(at: extras, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: extras.appendingPathComponent(name))
            }
            try manifest().write(to: payload.appendingPathComponent("about.json"))
            try readme.write(to: payload.appendingPathComponent("How to restore.txt"), atomically: true, encoding: .utf8)

            progress("Locking with your password…")
            let dmg = work.appendingPathComponent(BackupFile.fileName(for: Date(), beforeRestore: beforeRestore))
            try Vault.seal(folder: payload, to: dmg, password: password)
            try? FileManager.default.removeItem(at: payload)
            return (dmg, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Copies under a hidden name and renames, so a cloud app never uploads half a file
    /// and a pulled-out disk never leaves something that looks like a backup.
    static func deliver(_ dmg: URL, to destination: Destination) throws {
        let fm = FileManager.default
        guard destination.isAvailable else {
            throw ShellError(message: destination.kind == .external ? "Disk not connected." : "Folder not found.")
        }
        try fm.createDirectory(at: destination.folder, withIntermediateDirectories: true)
        let final = destination.folder.appendingPathComponent(dmg.lastPathComponent)
        let partial = destination.folder.appendingPathComponent(".\(dmg.lastPathComponent).partial")
        try? fm.removeItem(at: partial)
        try fm.copyItem(at: dmg, to: partial)
        let want = (try? dmg.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let got = (try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard want == got else {
            try? fm.removeItem(at: partial)
            throw ShellError(message: "The copy came out incomplete.")
        }
        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)

        for old in Retention.toDelete(BackupFile.list(in: destination.folder)) {
            try? fm.removeItem(at: old.url)
        }
    }

    private static func manifest() throws -> Data {
        let info: [String: String] = [
            "created": ISO8601DateFormatter().string(from: Date()),
            "computer": Host.current().localizedName ?? "",
            "hermes": Hermes.version() ?? "",
            "made_by": "Hermes Backup \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")",
        ]
        return try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    }

    private static let readme = """
    This is a backup of Hermes: memories, skills, sessions, scheduled jobs, settings and logins.

    Easiest: open the Hermes Backup app, go to Restore, and pick this backup.

    Without the app:
      1. Install Hermes on the Mac.
      2. Quit Hermes.
      3. In Terminal:  hermes import --force "/Volumes/Hermes Backup/hermes-backup.zip"
      4. Optional, for the desktop app's chat images: copy the "desktop" folder's contents
         into ~/Library/Application Support/Hermes
      5. Eject "Hermes Backup" and open Hermes.

    """

    // MARK: Restore

    struct RestoreResult {
        let safetyCopy: URL?
        let reopened: Bool
    }

    /// Replaces this Mac's Hermes with `backup`. Order matters: unlock first (so a wrong
    /// password stops us before anything is touched), then save what's here now, then close
    /// Hermes, then import.
    static func restore(_ backup: URL, password: String, safetyDestinations: [Destination],
                        safetyPassword: String, progress: Progress) throws -> RestoreResult {
        _ = try Hermes.requireCLI()
        let work = try scratch()
        defer { try? FileManager.default.removeItem(at: work) }

        // A cloud file may be a placeholder; copying it local forces the download.
        progress("Fetching the backup…")
        let local = work.appendingPathComponent("backup.dmg")
        try FileManager.default.copyItem(at: backup, to: local)

        progress("Unlocking…")
        let mount = work.appendingPathComponent("mnt")
        try Vault.open(local, at: mount, password: password)
        defer { Vault.close(mount) }
        let zip = mount.appendingPathComponent("hermes-backup.zip")
        guard FileManager.default.fileExists(atPath: zip.path) else {
            throw ShellError(message: "This file isn't a Hermes backup.")
        }

        var safetyCopy: URL?
        if Hermes.hasData {
            progress("Saving what's here now, just in case…")
            let made = try makeBackup(password: safetyPassword, beforeRestore: true, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: made.work) }
            var saved = false
            for d in safetyDestinations where d.isAvailable {
                if (try? deliver(made.dmg, to: d)) != nil {
                    saved = true
                    safetyCopy = d.folder.appendingPathComponent(made.dmg.lastPathComponent)
                }
            }
            guard saved else { throw ShellError(message: "Couldn't save a copy of the current Hermes first, so nothing was changed.") }
        }

        progress("Closing Hermes…")
        let appURL = try Hermes.quitDesktopApp()
        Hermes.stopGateway()
        // The desktop app's backend and the gateway take a moment to wind down.
        var others = Hermes.otherRunningProcesses()
        for _ in 0..<20 where !others.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
            others = Hermes.otherRunningProcesses()
        }
        guard others.isEmpty else {
            if let appURL { NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) }
            throw ShellError(message: "Hermes is still running somewhere else, maybe in Terminal. Close it, then try again. Nothing was changed.")
        }

        progress("Restoring…")
        try Hermes.restore(from: zip)

        let extras = mount.appendingPathComponent("desktop")
        if FileManager.default.fileExists(atPath: extras.path) {
            try? mergeCopy(from: extras, into: Hermes.desktopSupport)
        }

        var reopened = false
        if let appURL {
            progress("Opening Hermes…")
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            reopened = true
        }
        return RestoreResult(safetyCopy: safetyCopy, reopened: reopened)
    }

    /// Copies files in, replacing same-named ones and leaving the rest alone.
    private static func mergeCopy(from src: URL, into dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue {
                try mergeCopy(from: s, into: d)
            } else {
                try? fm.removeItem(at: d)
                try fm.copyItem(at: s, to: d)
            }
        }
    }
}
