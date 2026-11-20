import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var window: MainWindow.State

    var body: some View {
        Group {
            if !model.hasPassword {
                PasswordForm(isChange: false)
                    .padding(32)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if window.tab == .backup {
                BackupTab()
            } else {
                RestoreTab()
            }
        }
        .frame(minWidth: 560, minHeight: 600)
    }
}

/// The Backup / Restore switch, shown in the window's title bar.
struct TabSwitch: View {
    @EnvironmentObject private var window: MainWindow.State
    @EnvironmentObject private var model: AppModel

    var body: some View {
        EqualSegments(labels: ["Backup", "Restore"],
                      selection: Binding(get: { window.tab == .backup ? 0 : 1 },
                                         set: { window.tab = $0 == 0 ? .backup : .restore }))
            .frame(width: 240)
            .disabled(!model.hasPassword)
            .accessibilityLabel("Backup or Restore")
    }
}

/// SwiftUI's segmented picker sizes each segment to its text, so "Backup" and "Restore" end up
/// uneven inside the bar. AppKit's control can split the width equally.
private struct EqualSegments: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        c.selectedSegment = selection
        c.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: EqualSegments
        init(_ parent: EqualSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) { parent.selection = sender.selectedSegment }
    }
}

// MARK: Building blocks

/// A rounded panel that groups related rows, as in System Settings.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.horizontal, 16) }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.leading, 2)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 24)
    }
}

/// One entry in a `PopUpMenuButton` menu.
struct MenuChoice {
    let title: String
    var destructive = false
    var enabled = true
    var isSeparator = false
    var checked = false
    let action: () -> Void

    init(_ title: String, destructive: Bool = false, enabled: Bool = true, checked: Bool = false,
         action: @escaping () -> Void) {
        self.title = title; self.destructive = destructive; self.enabled = enabled
        self.checked = checked; self.action = action
    }

    static let separator: MenuChoice = { var m = MenuChoice("", action: {}); m.isSeparator = true; return m }()
}

/// A plain button that opens a native menu just below itself. SwiftUI's `Menu` and `Picker`
/// draw a system pop-up button (no custom colours or borders) whose menu opens over the button;
/// the design wants it below, left-aligned, with a tick on the current choice.
struct PopUpMenuButton<LabelView: View>: View {
    let items: () -> [MenuChoice]
    @ViewBuilder let label: LabelView
    @State private var anchor = AnchorView.Box()

    var body: some View {
        Button { show() } label: { label }
            .buttonStyle(.plain)
            .background(AnchorView(box: anchor))
    }

    private func show() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in items() {
            if choice.isSeparator { menu.addItem(.separator()); continue }
            let target = MenuTarget(choice.action)
            let item = NSMenuItem(title: choice.title, action: #selector(MenuTarget.fire), keyEquivalent: "")
            item.target = target
            item.representedObject = target   // NSMenuItem holds its target weakly
            item.isEnabled = choice.enabled
            item.state = choice.checked ? .on : .off
            var attrs: [NSAttributedString.Key: Any] = [:]
            if choice.destructive { attrs[.foregroundColor] = NSColor.systemRed }
            if choice.checked { attrs[.font] = NSFont.menuFont(ofSize: 0).withWeight(.semibold) }
            if !attrs.isEmpty {
                attrs[.font] = attrs[.font] ?? NSFont.menuFont(ofSize: 0)
                item.attributedTitle = NSAttributedString(string: choice.title, attributes: attrs)
            }
            menu.addItem(item)
        }
        if let view = anchor.view {
            menu.minimumWidth = view.bounds.width
            let below = view.isFlipped ? view.bounds.height + 6 : -6
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class MenuTarget: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }
}

/// Gives SwiftUI code the AppKit view behind a control, to open a menu against.
struct AnchorView: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let d = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

/// The schedule choice: a quiet field that opens a ticked menu below it.
struct IntervalPicker: View {
    @Binding var hours: Int
    static let choices: [(hours: Int, title: String)] =
        [(1, "Every hour"), (4, "Every 4 hours"), (12, "Twice a day"), (24, "Once a day")]

    var body: some View {
        PopUpMenuButton(items: {
            Self.choices.map { c in MenuChoice(c.title, checked: c.hours == hours) { hours = c.hours } }
        }) {
            HStack(spacing: 10) {
                Text(Self.choices.first { $0.hours == hours }?.title ?? "Every \(hours) hours")
                    .font(.system(size: 13))
                Spacer(minLength: 16)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(width: 150, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Back up")
        .accessibilityValue(Self.choices.first { $0.hours == hours }?.title ?? "")
        .accessibilityHint("Choose how often to back up")
    }
}

// MARK: Backup tab

struct BackupTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var changingPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Backup", subtitle: "Keep a copy of your Hermes data, ready when you need it.")

                StatusCard()

                SectionTitle("Backup destinations")
                Card {
                    ForEach(model.settings.destinations) { d in
                        DestinationRow(destination: d)
                        RowDivider()
                    }
                    AddDestinationMenu()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
                Text("Keep a copy on an external disk or in a cloud folder as well as on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.top, 10)

                SectionTitle("Automatic backups")
                Card {
                    HStack {
                        Text("Back up")
                        Spacer()
                        IntervalPicker(hours: $model.settings.intervalHours)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if model.settings.intervalHours >= 12 {
                        RowDivider()
                        SetTimesRows()
                    }
                    RowDivider()
                    NextBackupRow()
                    RowDivider()
                    HStack {
                        Text("Open at login")
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.isLoginItem }, set: { model.isLoginItem = $0 }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                Text(scheduleNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)

                SectionTitle("Backup password")
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "lock")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text("Saved in your Keychain")
                        Spacer()
                        Button("Change…") { changingPassword = true }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
            .font(.system(size: 13))
            .padding(32)
        }
        .sheet(isPresented: $changingPassword) {
            PasswordForm(isChange: true, done: { changingPassword = false })
                .padding(24)
                .frame(width: 440)
        }
    }
}

extension BackupTab {
    var scheduleNote: String {
        let catchUp = "If your Mac is asleep or Hermes Backup isn't open, it backs up once when it next can."
        return model.settings.activeTimes != nil ? "Times use this Mac's time zone. " + catchUp : catchUp
    }
}

/// "Set a time" for daily / twice daily, and the time pickers it reveals.
struct SetTimesRows: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let twice = model.settings.intervalHours == 12
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set a time")
                    if !model.settings.useSetTimes {
                        Text("Off: counts from the last backup")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.settings.useSetTimes }, set: { model.setUseSetTimes($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Back up at a set time")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if model.settings.useSetTimes {
                RowDivider()
                HStack(spacing: 10) {
                    Text(twice ? "Times" : "Time")
                    Spacer()
                    timePicker(0, label: twice ? "First backup time" : "Backup time")
                    if twice {
                        Text("and").foregroundStyle(.secondary)
                        timePicker(1, label: "Second backup time")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if twice, model.settings.setTimes.count >= 2,
                   model.settings.setTimes[0] == model.settings.setTimes[1] {
                    Text("These are the same time, so it backs up once a day. Pick two different times.")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    /// A native hour-and-minute field: follows the Mac's 12/24-hour setting and locale.
    private func timePicker(_ i: Int, label: String) -> some View {
        DatePicker(label, selection: Binding(
            get: {
                let t = model.settings.setTimes.indices.contains(i) ? model.settings.setTimes[i] : TimeOfDay(hour: 9, minute: 0)
                return Calendar.autoupdatingCurrent.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                guard model.settings.setTimes.indices.contains(i) else { return }
                let c = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: d)
                model.settings.setTimes[i] = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .accessibilityLabel(label)
    }
}

struct NextBackupRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                Text("Next backup")
                Spacer()
                Text(text(now: context.date)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private func text(now: Date) -> String {
        guard model.hasPassword else { return "After you choose a password" }
        guard let next = model.nextBackup(now: now) else { return "When a destination is available" }
        if next.timeIntervalSince(now) < 60 { return model.activity != nil ? "Running now" : "Within a minute" }
        let cal = Calendar.autoupdatingCurrent
        let time = next.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(next) { return "Today at \(time)" }
        if cal.isDateInTomorrow(next) { return "Tomorrow at \(time)" }
        return next.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

struct StatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(tint.opacity(0.12))
                        if model.health == .busy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: model.health == .good ? "checkmark" : "exclamationmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if let detail {
                            Text(detail)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    Button { Task { await model.backUpNow() } } label: {
                        Text("Back Up Now").fontWeight(.semibold).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.activity != nil || !model.hermesFound)
                }
                .padding(18)
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

    private var title: String {
        if let a = model.activity { return a }
        if let p = model.lastMessage ?? model.problem { return p }
        return model.lastBackup == nil ? "Not backed up yet" : "Last backup completed"
    }

    private var detail: String? {
        guard model.activity == nil, let last = model.lastBackup else { return nil }
        let ago = last.formatted(.relative(presentation: .named))
        return (model.lastMessage ?? model.problem) == nil ? ago.prefix(1).uppercased() + ago.dropFirst()
                                                           : "Last backup \(ago)"
    }
}

struct DestinationRow: View {
    @EnvironmentObject private var model: AppModel
    let destination: Destination

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: destination.symbol)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.name).font(.system(size: 14))
                Text(destination.displayPath).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(status.text)
                .font(.system(size: 12))
                .foregroundStyle(status.bad ? Color.red : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            PopUpMenuButton(items: {
                [MenuChoice("Show in Finder", enabled: destination.isAvailable) {
                    let fm = FileManager.default
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [fm.fileExists(atPath: destination.folder.path) ? destination.folder : destination.url])
                 },
                 MenuChoice("Remove", destructive: true) { model.removeDestination(destination) }]
            }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.22)))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Options for \(destination.name)")
            .help("Options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var status: (text: String, bad: Bool) {
        if !destination.isAvailable {
            let when = destination.lastSuccess.map { " · last copy \($0.formatted(.relative(presentation: .named)))" } ?? ""
            return ((destination.kind == .external ? "Not connected" : "Folder missing") + when,
                    destination.kind != .external)
        }
        if destination.isFailing { return (destination.lastError ?? "Failed", true) }
        if let s = destination.lastSuccess { return ("Saved \(s.formatted(.relative(presentation: .named)))", false) }
        return ("No copy yet", false)
    }
}

struct AddDestinationMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let added = Set(model.settings.destinations.map(\.path))
        let clouds = CloudFolder.detected().filter { !added.contains($0.path) }
        PopUpMenuButton(items: {
            clouds.map { c in MenuChoice(c.name) { model.addDestination(path: c.path) } }
                + [MenuChoice.separator, MenuChoice("External disk or other folder…") { pickFolder() }]
        }) {
            Label("Add a destination…", systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Pick an external disk, or any folder. Backups go in a \"Hermes Backups\" folder inside it."
        if FileManager.default.fileExists(atPath: "/Volumes") { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
        if panel.runModal() == .OK, let url = panel.url { model.addDestination(path: url.path) }
    }
}

// MARK: Restore tab

struct RestoreTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: BackupEntry.ID?
    @State private var confirming: URL?
    @State private var confirmingDate: Date?
    @State private var askPasswordFor: URL?
    @State private var otherPassword = ""
    @State private var result: String?
    @State private var deleting: BackupEntry?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "Restore a backup", subtitle: "Choose the backup you want to restore.")
                    HStack(alignment: .firstTextBaseline) {
                        Text("Available backups").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !model.backups.isEmpty {
                            Text("\(model.backups.count) backup\(model.backups.count == 1 ? "" : "s") · newest first")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 10)
                    Card {
                        if model.backups.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "externaldrive").font(.system(size: 22)).foregroundStyle(.secondary)
                                Text("No backups found").font(.system(size: 14, weight: .medium))
                                Text("Back up first, or plug in the disk that has your backups.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(model.backups.enumerated()), id: \.element.id) { i, entry in
                                    // No line touching the highlighted row; the highlight is the edge.
                                    if i > 0, entry.id != chosen?.id, model.backups[i - 1].id != chosen?.id {
                                        Divider().padding(.leading, 46).padding(.trailing, 12)
                                    } else if i > 0 {
                                        Color.clear.frame(height: 1)
                                    }
                                    Button { selection = entry.id } label: {
                                        BackupRow(entry: entry, latest: i == 0, selected: chosen?.id == entry.id)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete…", role: .destructive) { deleting = entry }
                                    }
                                    .accessibilityLabel(rowLabel(entry, latest: i == 0))
                                    .accessibilityAction(named: "Delete") { deleting = entry }
                                    .accessibilityAddTraits(chosen?.id == entry.id ? [.isSelected] : [])
                                }
                            }
                            .padding(6)
                        }
                    }
                    if let c = chosen {
                        Text("Selected: \(c.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                            .padding(.top, 12)
                    }
                }
                .font(.system(size: 13))
                .padding(32)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Restore from File…") { pickFile() }
                    .buttonStyle(.link)
                Spacer()
                if let a = model.activity {
                    ProgressView().controlSize(.small)
                    Text(a).foregroundStyle(.secondary)
                } else {
                    Button("Delete…") { deleting = chosen }
                        .controlSize(.large)
                        .disabled(chosen == nil)
                    Button {
                        guard let e = chosen, let url = e.bestCopy else { return }
                        confirmingDate = e.date
                        confirming = url
                    } label: {
                        Text("Restore Selected…").fontWeight(.semibold).padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(chosen == nil)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .disabled(model.activity != nil && confirming == nil)
        .alert(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Restore", role: .destructive) {
                if let url = confirming { run(url) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Hermes will close and go back to how it was then. What you have now is saved first.")
        }
        .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let e = deleting {
                    if selection == e.id { selection = nil }
                    result = model.deleteBackup(e)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleteMessage)
        }
        .sheet(isPresented: Binding(get: { askPasswordFor != nil }, set: { if !$0 { askPasswordFor = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("This backup has a different password").font(.headline)
                Text("Maybe it was made before you changed it, or on another Mac.").foregroundStyle(.secondary)
                SecureField("Password", text: $otherPassword).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { askPasswordFor = nil; otherPassword = "" }
                    Button("Unlock and Restore") {
                        let url = askPasswordFor
                        askPasswordFor = nil
                        if let url { run(url, password: otherPassword) }
                        otherPassword = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(otherPassword.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
        .alert(result ?? "", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
            Button("OK") { result = nil }
        }
    }

    private func rowLabel(_ e: BackupEntry, latest: Bool) -> String {
        var parts = ["Backup from \(e.date.formatted(date: .long, time: .shortened))"]
        if latest { parts.append("latest") }
        if e.beforeRestore { parts.append("saved before a restore") }
        parts.append("on " + e.copies.map(\.destination.name).joined(separator: " and "))
        parts.append(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
        return parts.joined(separator: ", ")
    }

    /// The picked backup, or the newest one until something is picked.
    private var chosen: BackupEntry? {
        model.backups.first { $0.id == selection } ?? model.backups.first
    }

    private var deleteTitle: String {
        guard let e = deleting else { return "Delete this backup?" }
        return "Delete the backup from \(e.date.formatted(date: .abbreviated, time: .shortened))?"
    }

    private var deleteMessage: String {
        guard let e = deleting else { return "" }
        let places = e.copies.map(\.destination.name).joined(separator: " and ")
        let onlyOne = model.backups.filter { !$0.beforeRestore }.count == 1 && !e.beforeRestore
        return "It moves to the Trash from \(places)." + (onlyOne ? " It's your only backup." : "")
    }

    private var confirmTitle: String {
        guard let d = confirmingDate else { return "Restore this backup?" }
        return "Restore Hermes to \(d.formatted(date: .abbreviated, time: .shortened))?"
    }

    private func run(_ url: URL, password: String? = nil) {
        Task {
            switch await model.restore(from: url, password: password) {
            case .done(let text): result = text
            case .wrongPassword: askPasswordFor = url
            case .failed(let text): result = text
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.prompt = "Restore"
        panel.message = "Pick a Hermes backup (.dmg)."
        if panel.runModal() == .OK, let url = panel.url {
            confirmingDate = BackupFile(url: url)?.date
            confirming = url
        }
    }
}

struct BackupRow: View {
    let entry: BackupEntry
    var latest = false
    var selected = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
                if selected {
                    Circle().fill(Color.accentColor)
                    Circle().fill(.white).frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 14, weight: .semibold))
                    if latest { Tag(text: "Latest", tint: .accentColor) }
                    if entry.beforeRestore { Tag(text: "Before restore", tint: .secondary) }
                }
                Text(entry.copies.map(\.destination.name).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.55)))
            }
        }
    }

    private struct Tag: View {
        let text: String
        let tint: Color

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((tint == .secondary ? Color.primary.opacity(0.08) : tint.opacity(0.18)),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

// MARK: Password

struct PasswordForm: View {
    @EnvironmentObject private var model: AppModel
    let isChange: Bool
    var done: () -> Void = {}

    @State private var first = ""
    @State private var second = ""
    @State private var wroteItDown = false

    private var valid: Bool { first.count >= 8 && first == second && wroteItDown }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isChange ? "Change backup password" : "Choose a backup password").font(.title2.bold())
            Text("Backups hold your Hermes logins, so each one is locked with this password. Without it, nobody can open them, including you.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isChange {
                Text("Backups you already have keep the old password.")
                    .foregroundStyle(.secondary)
            }
            SecureField("Password (8 or more characters)", text: $first).textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $second).textFieldStyle(.roundedBorder)
            if !second.isEmpty && first != second {
                Text("These don't match.").font(.callout).foregroundStyle(.red)
            }
            Toggle("I've written it down somewhere safe", isOn: $wroteItDown)
            HStack {
                Spacer()
                if isChange { Button("Cancel") { done() } }
                Button(isChange ? "Change" : "Save and Start") {
                    model.setPassword(first)
                    done()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
