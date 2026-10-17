import Foundation
import OSLog

enum AppGroup {
    /// Resolved at build time from `APP_GROUP_ID` (see Config/Base.xcconfig).
    static var identifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String ?? ""
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    private static let logger = Logger(subsystem: "io.github.phdz-ng.fishbrain", category: "app-group")

    /// Where shared files live, so the app and the widget read and write the same ones.
    ///
    /// Only a team-signed build has a real, shared App Group (its ID starts with the 10-character
    /// team ID); then that is the group container. Otherwise `containerURL` can't be trusted: it
    /// may return the app's own private folder, and the widget can be handed a different, empty
    /// "Group Containers" folder for the very same ID. So without a team both processes always use
    /// a real folder they are granted through a narrow sandbox exception:
    /// `~/Library/Application Support/FishBrain`.
    static func storageDirectory() -> URL {
        let resolved = resolveStorageDirectory(identifier: identifier, container: containerURL, shared: sharedDirectory)
        if resolved == sharedDirectory {
            logger.info("No team-signed App Group; sharing through \(sharedDirectory.path, privacy: .public)")
        }
        return resolved
    }

    static func resolveStorageDirectory(identifier: String, container: URL?, shared: URL) -> URL {
        if isTeamPrefixed(identifier), let container, container.pathComponents.contains("Group Containers") {
            return container
        }
        return shared
    }

    /// Team IDs are 10 uppercase letters or digits, and a provisioned group ID starts with one.
    static func isTeamPrefixed(_ identifier: String) -> Bool {
        identifier.range(of: #"^[A-Z0-9]{10}\."#, options: .regularExpression) != nil
    }

    /// The real home folder, even inside a sandbox (where `NSHomeDirectory()` is the container).
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var sharedDirectory: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/FishBrain", isDirectory: true)
    }
}

/// Moves an existing library to the current shared location. Earlier builds kept it in the app's
/// own private folder, where the widget could not see it.
///
/// A file is copied when the target lacks it, or when an old copy is *newer* than the target (an
/// old build kept saving there after an earlier copy). Whatever is replaced is first kept as
/// `<name>.backup-<time>`, and the originals are left in place. Once the new build is saving to the
/// target, the old copies are older and are never touched again.
enum StorageMigration {
    static let fileNames = [DeckStorage.fileName, PlaybackStorage.fileName, SettingsStorage.fileName]

    private static func modified(_ url: URL, _ fileManager: FileManager) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Returns the names of the files it copied.
    @discardableResult
    static func copyMissingFiles(
        from sources: [URL],
        to target: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [String] {
        var copied: [String] = []
        for name in fileNames {
            let destination = target.appendingPathComponent(name)
            let existing = fileManager.fileExists(atPath: destination.path)
            let existingDate = existing ? modified(destination, fileManager) : nil

            // The newest old copy that is worth adopting.
            let candidates = sources
                .filter { $0.standardizedFileURL != target.standardizedFileURL }
                .map { $0.appendingPathComponent(name) }
                .filter { fileManager.fileExists(atPath: $0.path) }
                .compactMap { url in modified(url, fileManager).map { (url: url, date: $0) } }
                .sorted { $0.date > $1.date }
            guard let best = candidates.first else { continue }
            if let existingDate, best.date <= existingDate { continue }

            do {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                if existing {
                    let stamp = backupFormatter.string(from: now)
                    try fileManager.copyItem(at: destination, to: target.appendingPathComponent("\(name).backup-\(stamp)"))
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: best.url, to: destination)
                copied.append(name)
            } catch {
                continue
            }
        }
        return copied
    }

    private static let backupFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Call once at app launch, before the stores load.
    static func migrateIfNeeded() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Where earlier builds kept the library: the group container (if there was one), the app's own
        // Application Support, and the real ~/Library/Application Support/FishBrain that team-less
        // builds share with the widget. A team-signed release reads from the group container, so
        // without the last one it would start empty next to a library saved by a development build.
        let legacy = [
            AppGroup.containerURL,
            applicationSupport.appendingPathComponent("FishBrain", isDirectory: true),
            AppGroup.sharedDirectory,
        ].compactMap { $0 }
        copyMissingFiles(from: legacy, to: AppGroup.storageDirectory())
    }
}
