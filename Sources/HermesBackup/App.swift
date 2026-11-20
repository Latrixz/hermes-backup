import AppKit
import SwiftUI

@main
struct HermesBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() { SelfTest.runIfAsked() }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image(for: model.health))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Updater.shared.start()
            if !AppModel.shared.hasPassword { MainWindow.show(.backup) }
        }
    }

    /// Opening the app again from Finder or Launchpad brings the window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindow.show(.backup) }
        return true
    }
}

extension AppModel {
    var menuSymbol: String {
        switch health {
        case .good: return "externaldrive.badge.checkmark"
        case .busy: return "arrow.triangle.2.circlepath"
        case .warning: return "externaldrive.badge.exclamationmark"
        }
    }
}

/// The menu bar panel: a quiet status header, one clear primary action, the rest out of the way.
struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusSummary()
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
                MenuRow("Back Up Now", symbol: "arrow.triangle.2.circlepath", prominent: true,
                        disabled: model.activity != nil || !model.hasPassword) {
                    Task { await model.backUpNow() }
                }
                MenuRow("Restore…", symbol: "clock.arrow.circlepath") { MainWindow.show(.restore) }
                MenuRow("Open Hermes Backup…", symbol: "macwindow") { MainWindow.show(.backup) }
            }
            .padding(6)
            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
                if let r = updater.available {
                    MenuRow(updateTitle(r), symbol: "arrow.down.circle", prominent: true,
                            disabled: updater.phase != .idle) { updater.offer() }
                } else {
                    MenuRow(updater.phase == .checking ? "Checking for Updates…" : "Check for Updates…",
                            symbol: "arrow.down.circle", disabled: updater.phase != .idle) {
                        Task { await updater.check(manual: true) }
                    }
                }
                MenuRow("Quit Hermes Backup", symbol: "power", quiet: true) { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 290)
    }

    private func updateTitle(_ r: Updater.Release) -> String {
        switch updater.phase {
        case .downloading: return "Downloading \(r.version)…"
        case .installing: return "Installing \(r.version)…"
        default: return "Update to \(r.version)…"
        }
    }
}

private struct StatusSummary: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Re-reads "12 minutes ago" while the panel stays open.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.12))
                    Circle().strokeBorder(tint.opacity(0.25), lineWidth: 1)
                    if model.health == .busy {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                    } else {
                        Image(systemName: model.health == .good ? "checkmark" : "exclamationmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint.opacity(0.9))
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes Backup").font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var tint: Color {
        switch model.health {
        case .good: return .green
        case .busy: return .accentColor
        case .warning: return .orange
        }
    }

    private var detail: String {
        if let a = model.activity { return a }
        if let p = model.problem { return p }
        if let last = model.lastBackup { return "Last backed up \(last.formatted(.relative(presentation: .named)))" }
        return "Not backed up yet"
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    var prominent = false
    var quiet = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, prominent: Bool = false, quiet: Bool = false,
         disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.prominent = prominent
        self.quiet = quiet; self.disabled = disabled; self.action = action
    }

    var body: some View {
        Button {
            // Close the panel first, so a window opened by the action lands in front of it.
            NSApp.keyWindow?.close()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                    .foregroundStyle(quiet ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !disabled ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.replacingOccurrences(of: "…", with: ""))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
}

/// The app has no Dock icon, so its one window is managed by hand: shown on demand and
/// brought to the front over whatever else is open.
@MainActor
enum MainWindow {
    enum Tab: Hashable { case backup, restore }

    final class State: ObservableObject {
        @Published var tab: Tab = .backup
    }

    static let state = State()
    private static var window: NSWindow?
    private static let toolbarDelegate = ToolbarDelegate()

    final class ToolbarDelegate: NSObject, NSToolbarDelegate {
        static let tabs = NSToolbarItem.Identifier("tabs")

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabs] }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.tabs] }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: id)
            MainActor.assumeIsolated {
                let host = NSHostingView(rootView: TabSwitch()
                    .environmentObject(MainWindow.state)
                    .environmentObject(AppModel.shared))
                host.frame.size = host.fittingSize
                item.view = host
            }
            return item
        }
    }

    static func show(_ tab: Tab) {
        state.tab = tab
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Hermes Backup"
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            // The Backup / Restore switch sits in the title bar, centred, beside the window buttons.
            let toolbar = NSToolbar(identifier: "main")
            toolbar.delegate = toolbarDelegate
            toolbar.centeredItemIdentifiers = [ToolbarDelegate.tabs]
            toolbar.displayMode = .iconOnly
            w.toolbar = toolbar
            w.toolbarStyle = .unified
            w.contentView = NSHostingView(rootView: MainView()
                .environmentObject(AppModel.shared)
                .environmentObject(state))
            w.setContentSize(NSSize(width: 640, height: 780))
            w.center()
            window = w
        }
        AppModel.shared.refreshBackups()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
