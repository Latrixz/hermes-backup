import Foundation

/// A folder copies are kept in: on this Mac, on an external disk, or in a cloud-synced folder.
/// Cloud uploads are left to the cloud app (Dropbox, iCloud Drive, Google Drive, OneDrive).
struct Destination: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case local, external, cloud }

    var id = UUID()
    var path: String
    var lastSuccess: Date?
    var lastAttempt: Date?
    var lastError: String?

    var url: URL { URL(fileURLWithPath: path) }

    /// Copies go in a "Hermes Backups" folder inside what was picked, unless that's what was picked.
    var folder: URL {
        url.lastPathComponent == Destination.folderName ? url : url.appendingPathComponent(Destination.folderName)
    }
    static let folderName = "Hermes Backups"

    var kind: Kind {
        if path.hasPrefix("/Volumes/") { return .external }
        if path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/") { return .cloud }
        return .local
    }

    /// An unplugged disk can leave an empty /Volumes/<name> folder on the Mac's own disk;
    /// writing there would look like a backup to the external disk and isn't one.
    var isAvailable: Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        if kind == .external {
            let root = (try? url.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem
            return root == false
        }
        return true
    }

    var name: String {
        switch kind {
        case .external:
            return url.pathComponents.count > 2 ? url.pathComponents[2] : "External disk"
        case .cloud:
            if path.contains("/Mobile Documents/") { return "iCloud Drive" }
            let parts = url.pathComponents
            if let i = parts.firstIndex(of: "CloudStorage"), i + 1 < parts.count {
                return CloudFolder.friendlyName(parts[i + 1])
            }
            return "Cloud folder"
        case .local:
            return "This Mac"
        }
    }

    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = folder.path
        if let r = p.range(of: "/Library/Mobile Documents/com~apple~CloudDocs") { p = "iCloud Drive" + p[r.upperBound...] }
        else if let r = p.range(of: "/Library/CloudStorage/") { p = String(p[r.upperBound...]) }
        else if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        return kind == .local ? p : p.replacingOccurrences(of: "/", with: " / ").trimmingCharacters(in: .whitespaces)
    }

    var symbol: String {
        switch kind {
        case .local: return "laptopcomputer"
        case .external: return "externaldrive"
        case .cloud: return "icloud"
        }
    }
}

/// Cloud folders already on this Mac, offered as one-click destinations.
struct CloudFolder: Identifiable {
    let name: String
    let path: String
    var id: String { path }

    static func detected() -> [CloudFolder] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [CloudFolder] = []
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { found.append(CloudFolder(name: "iCloud Drive", path: icloud.path)) }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        for entry in (try? fm.contentsOfDirectory(atPath: storage.path)) ?? [] where !entry.hasPrefix(".") {
            var url = storage.appendingPathComponent(entry)
            // Google Drive's own files sit one level down.
            let myDrive = url.appendingPathComponent("My Drive")
            if fm.fileExists(atPath: myDrive.path) { url = myDrive }
            found.append(CloudFolder(name: friendlyName(entry), path: url.path))
        }
        return found
    }

    static func friendlyName(_ folder: String) -> String {
        if folder.hasPrefix("GoogleDrive") { return "Google Drive" }
        if folder.hasPrefix("OneDrive") { return "OneDrive" }
        if folder.hasPrefix("Dropbox") { return "Dropbox" }
        if folder.hasPrefix("Box") { return "Box" }
        return folder.components(separatedBy: "-").first ?? folder
    }
}

/// One backup file as it sits in a destination folder.
struct BackupFile: Hashable {
    let url: URL
    let date: Date
    let size: Int64
    let beforeRestore: Bool

    static let prefix = "Hermes Backup "
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f
    }()

    /// The date is in the name, because cloud folders don't reliably keep file dates.
    static func fileName(for date: Date, beforeRestore: Bool) -> String {
        prefix + formatter.string(from: date) + (beforeRestore ? " (before restore)" : "") + ".dmg"
    }

    init?(url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix(Self.prefix), name.hasSuffix(".dmg") else { return nil }
        let stamp = String(name.dropFirst(Self.prefix.count).prefix(19))
        guard let date = Self.formatter.date(from: stamp) else { return nil }
        self.url = url
        self.date = date
        self.beforeRestore = name.contains("(before restore)")
        self.size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func list(in folder: URL) -> [BackupFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { BackupFile(url: folder.appendingPathComponent($0)) }
            .sorted { $0.date > $1.date }
    }
}

/// Which old copies to delete: keep the newest 24, then one per day for two weeks,
/// one per week for two months, one per month for a year. At ~8 MB each that is
/// under half a gigabyte per destination.
enum Retention {
    static func toDelete(_ files: [BackupFile], now: Date = Date()) -> [BackupFile] {
        let cal = Calendar.current
        var keep = Set<URL>()
        let regular = files.filter { !$0.beforeRestore }.sorted { $0.date > $1.date }
        regular.prefix(24).forEach { keep.insert($0.url) }

        func keepNewest(per component: (Date) -> DateComponents, within days: Int) {
            var seen = Set<DateComponents>()
            for f in regular where now.timeIntervalSince(f.date) < Double(days) * 86_400 {
                if seen.insert(component(f.date)).inserted { keep.insert(f.url) }
            }
        }
        keepNewest(per: { cal.dateComponents([.year, .month, .day], from: $0) }, within: 14)
        keepNewest(per: { cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) }, within: 60)
        keepNewest(per: { cal.dateComponents([.year, .month], from: $0) }, within: 366)

        files.filter(\.beforeRestore).sorted { $0.date > $1.date }.prefix(5).forEach { keep.insert($0.url) }
        return files.filter { !keep.contains($0.url) }
    }
}
