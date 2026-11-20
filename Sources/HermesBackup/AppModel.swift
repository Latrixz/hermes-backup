import AppKit
import Foundation
import ServiceManagement
import UserNotifications

struct Settings: Codable {
    var destinations: [Destination] = []
    var intervalHours = 1 { didSet { if intervalHours != oldValue { setTimesChanged = Date() } } }
    var lastAlert: Date?
    /// Opt-in for daily / twice daily: run at these local times instead of counting from the last backup.
    var useSetTimes = false
    var setTimes: [TimeOfDay] = [] { didSet { if setTimes != oldValue { setTimesChanged = Date() } } }
    var setTimesChanged: Date?

    /// The times the scheduler uses, or nil for "count from the last backup".
    var activeTimes: [TimeOfDay]? {
        guard useSetTimes, intervalHours == 24 || intervalHours == 12 else { return nil }
        let wanted = intervalHours == 24 ? 1 : 2
        return setTimes.count >= wanted ? Array(setTimes.prefix(wanted)) : nil
    }

    init() {}

    // Every key optional, so a settings file from an older version still loads. A missing key
    // must never throw: that would fall back to defaults and drop the user's destinations.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinations = try c.decodeIfPresent([Destination].self, forKey: .destinations) ?? []
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 1
        lastAlert = try c.decodeIfPresent(Date.self, forKey: .lastAlert)
        useSetTimes = try c.decodeIfPresent(Bool.self, forKey: .useSetTimes) ?? false
        setTimes = try c.decodeIfPresent([TimeOfDay].self, forKey: .setTimes) ?? []
        setTimesChanged = try c.decodeIfPresent(Date.self, forKey: .setTimesChanged)
    }
}

/// One backup, wherever its copies are.
struct BackupEntry: Identifiable, Hashable {
    let name: String
    let date: Date
    let size: Int64
    let beforeRestore: Bool
    var copies: [(destination: Destination, url: URL)]
    var id: String { name }

    static func == (a: BackupEntry, b: BackupEntry) -> Bool { a.name == b.name && a.copies.count == b.copies.count }
    func hash(into h: inout Hasher) { h.combine(name) }

    /// Prefer a copy that's already on this Mac or a plugged-in disk over one that may need downloading.
    var bestCopy: URL? {
        (copies.first { $0.destination.kind != .cloud } ?? copies.first)?.url
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings = Settings() { didSet { save() } }
    @Published private(set) var activity: String?
    @Published private(set) var backups: [BackupEntry] = []
    @Published private(set) var hasPassword = Keychain.hasPassword
    @Published private(set) var hermesFound = Hermes.cli != nil
    @Published var lastMessage: String?

    private var timer: Timer?
    private let settingsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HermesBackup")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    init() {
        if let data = try? Data(contentsOf: settingsURL),
           let s = try? JSONDecoder.iso.decode(Settings.self, from: data) {
            settings = s
        } else {
            let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            settings.destinations = [Destination(path: docs.path)]
        }
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if UserDefaults.standard.object(forKey: "loginItemOffered") == nil {
            UserDefaults.standard.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tick() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        // Plugging the disk in or waking up is when a copy is most likely overdue.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    AppModel.shared.tick()
                }
            }
        }
        refreshBackups()
        tick()
    }

    // MARK: Status

    enum Health { case good, busy, warning }

    var health: Health {
        if activity != nil { return .busy }
        return problem == nil ? .good : .warning
    }

    var lastBackup: Date? { settings.destinations.compactMap(\.lastSuccess).max() }

    /// The one thing most worth fixing, in plain words. Nil when all is well.
    var problem: String? {
        if !hermesFound { return "Hermes isn't installed on this Mac." }
        if !Hermes.hasData { return "Hermes has nothing to back up yet." }
        if !hasPassword { return "Choose a password to start backing up." }
        if settings.destinations.isEmpty { return "Add a place to keep backups." }
        if let failing = settings.destinations.first(where: \.isFailing) {
            return "\(failing.name): \(failing.lastError ?? "last backup failed")"
        }
        guard let last = lastBackup else { return "No backup yet." }
        if Date().timeIntervalSince(last) > 26 * 3600 { return "No backup for over a day." }
        if let disk = settings.destinations.first(where: { $0.kind == .external && $0.isStale(days: 7) }) {
            return "Plug in \(disk.name). Its last copy is over a week old."
        }
        return nil
    }

    var isLoginItem: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }

    // MARK: Settings

    func setPassword(_ password: String) {
        hasPassword = Keychain.setPassword(password)
        tick()
    }

    func addDestination(path: String) {
        guard !settings.destinations.contains(where: { $0.path == path }) else { return }
        settings.destinations.append(Destination(path: path))
        refreshBackups()
        tick()
    }

    func removeDestination(_ d: Destination) {
        settings.destinations.removeAll { $0.id == d.id }
        refreshBackups()
    }

    /// Preview renders change settings in memory only; they must never write the user's file.
    nonisolated(unsafe) static var readOnly = false

    private func save() {
        guard !Self.readOnly else { return }
        if let data = try? JSONEncoder.iso.encode(settings) { try? data.write(to: settingsURL, options: .atomic) }
    }

    // MARK: Backing up

    /// Runs a backup when any reachable destination is due.
    func tick() {
        hermesFound = Hermes.cli != nil
        guard activity == nil, hermesFound, hasPassword, Hermes.hasData else { return }
        let now = Date()
        let due = settings.destinations.contains { d in
            d.isAvailable
                && Schedule.isDue(intervalHours: settings.intervalHours, times: settings.activeTimes,
                                  lastSuccess: d.lastSuccess, timesChanged: settings.setTimesChanged, now: now)
                && (d.lastAttempt.map { now.timeIntervalSince($0) >= 15 * 60 } ?? true)   // back off after a failure
        }
        if due { Task { await backUpNow(scheduled: true) } }
    }

    /// When the next automatic backup will run, from the same calculation `tick` uses.
    /// Nil when no destination is reachable.
    func nextBackup(now: Date = Date()) -> Date? {
        settings.destinations.filter(\.isAvailable).map {
            Schedule.nextRun(intervalHours: settings.intervalHours, times: settings.activeTimes,
                             lastSuccess: $0.lastSuccess, timesChanged: settings.setTimesChanged, now: now)
        }.min().map { max($0 + (settings.activeTimes == nil ? Schedule.earlyGrace : 0), now) }
    }

    /// Turning set times on starts from the last backup's time, so nothing moves until changed.
    func setUseSetTimes(_ on: Bool) {
        if on && settings.setTimes.count < 2 {
            let first = lastBackup.map { TimeOfDay(near: $0) } ?? TimeOfDay(hour: 9, minute: 0)
            settings.setTimes = [first, first.adding(hours: 12)]
        }
        settings.useSetTimes = on
        settings.setTimesChanged = Date()
    }

    func backUpNow(scheduled: Bool = false) async {
        guard activity == nil else { return }
        guard let password = Keychain.password() else { hasPassword = false; return }
        activity = "Starting…"
        lastMessage = nil
        let destinations = settings.destinations
        let result = await Task.detached { () -> Result<[UUID: String], Error> in
            do {
                let made = try Engine.makeBackup(password: password) { step in
                    Task { @MainActor in AppModel.shared.activity = step }
                }
                defer { try? FileManager.default.removeItem(at: made.work) }
                Task { @MainActor in AppModel.shared.activity = "Saving copies…" }
                // Destination → "" when saved, or the reason it wasn't.
                var outcome: [UUID: String] = [:]
                for d in destinations where d.isAvailable {
                    do { try Engine.deliver(made.dmg, to: d); outcome[d.id] = "" }
                    catch { outcome[d.id] = error.localizedDescription }
                }
                return .success(outcome)
            } catch {
                return .failure(error)
            }
        }.value

        let now = Date()
        switch result {
        case .success(let outcome):
            for i in settings.destinations.indices {
                guard let entry = outcome[settings.destinations[i].id] else { continue }
                settings.destinations[i].lastAttempt = now
                if !entry.isEmpty {
                    settings.destinations[i].lastError = entry
                } else {
                    settings.destinations[i].lastSuccess = now
                    settings.destinations[i].lastError = nil
                }
            }
            if outcome.isEmpty { lastMessage = "None of your backup places are reachable right now." }
        case .failure(let error):
            for i in settings.destinations.indices where settings.destinations[i].isAvailable {
                settings.destinations[i].lastAttempt = now
                settings.destinations[i].lastError = error.localizedDescription
            }
            lastMessage = error.localizedDescription
        }
        activity = nil
        refreshBackups()
        if scheduled, lastMessage != nil || settings.destinations.contains(where: \.isFailing) {
            alert(lastMessage ?? problem ?? "A backup didn't save.")
        }
    }

    /// At most one notification every 6 hours, so a disk left unplugged doesn't nag.
    private func alert(_ text: String) {
        if let last = settings.lastAlert, Date().timeIntervalSince(last) < 6 * 3600 { return }
        settings.lastAlert = Date()
        let content = UNMutableNotificationContent()
        content.title = "Hermes backup failed"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }

    // MARK: Restoring

    func refreshBackups() {
        var byName: [String: BackupEntry] = [:]
        for d in settings.destinations where d.isAvailable {
            for f in BackupFile.list(in: d.folder) {
                let name = f.url.lastPathComponent
                if byName[name] == nil {
                    byName[name] = BackupEntry(name: name, date: f.date, size: f.size,
                                               beforeRestore: f.beforeRestore, copies: [])
                }
                byName[name]?.copies.append((d, f.url))
            }
        }
        backups = byName.values.sorted { $0.date > $1.date }
    }

    /// Moves every copy of a backup to the Trash (iCloud Drive keeps it in Recently Deleted).
    /// Returns what went wrong, or nil.
    func deleteBackup(_ entry: BackupEntry) -> String? {
        guard activity == nil else { return "Wait for the current backup to finish." }
        defer { refreshBackups() }
        var failed: [String] = []
        for copy in entry.copies {
            do { try FileManager.default.trashItem(at: copy.url, resultingItemURL: nil) }
            catch { failed.append(copy.destination.name) }
        }
        return failed.isEmpty ? nil : "Couldn't delete the copy on \(failed.joined(separator: " and "))."
    }

    enum RestoreOutcome { case done(String), wrongPassword, failed(String) }

    func restore(from file: URL, password: String? = nil) async -> RestoreOutcome {
        guard activity == nil else { return .failed("Wait for the current backup to finish.") }
        guard let current = Keychain.password() else { return .failed("Choose a password first.") }
        let unlock = password ?? current
        activity = "Starting…"
        defer { activity = nil; refreshBackups() }
        var safety = settings.destinations.filter { $0.kind != .cloud && $0.isAvailable }
        if safety.isEmpty { safety = settings.destinations.filter(\.isAvailable) }
        let targets = safety
        let result = await Task.detached { () -> Result<Engine.RestoreResult, Error> in
            Result {
                try Engine.restore(file, password: unlock, safetyDestinations: targets,
                                   safetyPassword: current) { step in
                    Task { @MainActor in AppModel.shared.activity = step }
                }
            }
        }.value
        switch result {
        case .success(let r):
            var text = "Hermes is restored."
            if r.safetyCopy != nil { text += " What you had before is saved as a backup marked \"before restore\"." }
            if !r.reopened { text += " Open Hermes to carry on." }
            return .done(text)
        case .failure(let e) where e is Vault.WrongPassword:
            return .wrongPassword
        case .failure(let e):
            return .failed(e.localizedDescription)
        }
    }
}

extension Destination {
    var isFailing: Bool {
        guard let err = lastError, !err.isEmpty, let attempt = lastAttempt else { return false }
        return attempt >= (lastSuccess ?? .distantPast)
    }

    func isStale(days: Int) -> Bool {
        guard let s = lastSuccess else { return true }
        return Date().timeIntervalSince(s) > Double(days) * 86_400
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
