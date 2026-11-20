import AppKit
import SwiftUI

/// Headless checks for development, without the UI and without touching the live Hermes:
///   HermesBackup --test-backup <folder> <password>        make a backup and deliver it to <folder>
///   HermesBackup --test-unlock <dmg> <password> <outdir>  unlock a backup and copy its contents out
///   HermesBackup --test-render-menu <png>                 draw the menu bar panel to an image
///   HermesBackup --test-render-window <png> [restore|twice]  draw the main window's content to an image
///   HermesBackup --test-update-check                      show the newest release on GitHub
///   HermesBackup --test-update <app>                      download, verify and swap the newest release into <app>
enum SelfTest {
    static func runIfAsked() {
        let a = CommandLine.arguments
        guard a.count >= 2, a[1].hasPrefix("--test-") else { return }
        do {
            switch a[1] {
            case "--test-backup" where a.count == 4:
                let made = try Engine.makeBackup(password: a[3]) { print("·", $0) }
                defer { try? FileManager.default.removeItem(at: made.work) }
                let d = Destination(path: a[2])
                try Engine.deliver(made.dmg, to: d)
                print("saved", d.folder.appendingPathComponent(made.dmg.lastPathComponent).path)
            case "--test-unlock" where a.count == 5:
                let mount = try Engine.scratch().appendingPathComponent("mnt")
                try Vault.open(URL(fileURLWithPath: a[2]), at: mount, password: a[3])
                defer { Vault.close(mount) }
                let out = URL(fileURLWithPath: a[4])
                try? FileManager.default.removeItem(at: out)
                try FileManager.default.copyItem(at: mount, to: out)
                print("unlocked into", out.path)
            case "--test-render-menu" where a.count == 3:
                // Draws the menu bar panel to a PNG, in dark mode, without showing it.
                MainActor.assumeIsolated {
                    let view = MenuPanel().environmentObject(AppModel.shared)
                        .background(Color(white: 0.16))
                        .environment(\.colorScheme, .dark)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
                    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
                }
                print("rendered", a[2])
            case "--test-render-window" where a.count >= 3:
                // Draws the main window's content (Backup tab, or Restore with a 4th arg "restore")
                // to a PNG in dark mode, in a window that is never shown.
                MainActor.assumeIsolated {
                    AppModel.readOnly = true   // a preview never writes the user's settings
                    MainWindow.state.tab = a.count > 3 && a[3] == "restore" ? .restore : .backup
                    if a.count > 3 && a[3] == "twice" {   // preview set times, in memory only
                        AppModel.shared.settings.intervalHours = 12
                        AppModel.shared.setUseSetTimes(true)
                    }
                    AppModel.shared.refreshBackups()
                    let host = NSHostingView(rootView: MainView()
                        .environmentObject(AppModel.shared)
                        .environmentObject(MainWindow.state)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: .darkAqua)
                    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                                     styleMask: [.titled], backing: .buffered, defer: false)
                    w.appearance = NSAppearance(named: .darkAqua)
                    w.contentView = host
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    host.layoutSubtreeIfNeeded()
                    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
                }
                print("rendered", a[2])
            case "--test-update-check":
                let r = try waitFor { try await Updater.fetchLatest() }
                print("this copy:", Updater.currentVersion)
                print("latest:", r.map { "\($0.version) \($0.dmg)" } ?? "no release")
                print("newer:", r.map { Updater.isNewer($0.version, than: Updater.currentVersion) } ?? false)
            case "--test-update" where a.count == 3:
                guard let r = try waitFor({ try await Updater.fetchLatest() }) else { print("no release"); exit(1) }
                let staged = try waitFor { try await Updater.download(r) }
                print("verified", r.version)
                try Updater.replace(URL(fileURLWithPath: a[2]), with: staged, relaunch: false)
                print("installed into", a[2])
            default:
                print("unknown test")
                exit(2)
            }
            exit(0)
        } catch {
            print("FAILED:", error.localizedDescription)
            exit(1)
        }
    }

    /// Runs async work to completion from the synchronous self-test.
    private static func waitFor<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }
}
