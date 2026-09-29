import AppKit
import Foundation

/// Keeps the frame that triggered a lock and shows it as the wallpaper, which macOS uses as the
/// lock-screen background. The original wallpaper is remembered on disk and put back after unlock,
/// even if Mog was quit or crashed in between.
///
/// Stored in ~/.config/mog/intruders (0700), one JPEG per lock, newest `keep` kept.
public enum IntruderPhoto {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mog/intruders")
    }
    private static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mog/wallpaper-backup.json")
    }
    public static var keep = 20

    /// Saves the photo. Returns its file URL.
    public static func save(_ jpeg: Data) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("intruder-\(stamp).jpg")
        try jpeg.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune()
        return url
    }

    public static func all() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func prune() {
        for old in all().dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Wallpaper swap. Main thread only (NSWorkspace wallpaper calls silently no-op elsewhere).
    //
    // Two backups, taken together before the swap:
    // 1. A copy of macOS's wallpaper store (com.apple.wallpaper/Store/Index.plist). It holds every kind
    //    of wallpaper: plain images, but also the built-in dynamic, Aerial and Sequoia/Tahoe ones and
    //    shuffled folders, which are not image files. Restore = put the copy back + restart
    //    WallpaperAgent (it only reads the store at launch). Verified on macOS 26: a dynamic
    //    wallpaper comes back exactly.
    // 2. The per-screen image URLs from NSWorkspace, as before. Fallback if the store is missing,
    //    unreadable or its restore doesn't stick. For a dynamic wallpaper this URL is a cached
    //    still that `setDesktopImageURL` refuses ("The file doesn't exist"): that was the bug.

    private static var storeCopyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mog/wallpaper-store-backup.plist")
    }
    /// macOS's wallpaper store. Undocumented; if it moves or changes format, the URL fallback still works.
    public static var systemStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    private struct Backup: Codable {
        struct Entry: Codable {
            var screenID: UInt32
            var url: URL
            var scaling: Int?
            var allowClipping: Bool?
        }
        var entries: [Entry]
    }

    /// Records the current wallpaper (unless a backup already exists: a previous swap wasn't restored
    /// yet, and overwriting it would lose the real original), then shows `photo` on every screen.
    @MainActor
    public static func showOnLockScreen(_ photo: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: backupURL.path) {
            // Store copy first: the JSON backup is what marks a swap as pending, so it goes last.
            try? fm.removeItem(at: storeCopyURL)
            if WallpaperStore.isUsable(at: systemStoreURL) {
                do {
                    try fm.copyItem(at: systemStoreURL, to: storeCopyURL)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeCopyURL.path)
                } catch {
                    try? fm.removeItem(at: storeCopyURL)  // URL fallback only
                }
            }
            let entries: [Backup.Entry] = NSScreen.screens.compactMap { screen in
                guard let id = screen.displayID, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
                let opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                return Backup.Entry(screenID: id, url: url,
                                    scaling: (opts[.imageScaling] as? NSNumber)?.intValue,
                                    allowClipping: (opts[.allowClipping] as? NSNumber)?.boolValue)
            }
            try JSONEncoder().encode(Backup(entries: entries)).write(to: backupURL, options: .atomic)
        }
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(photo, for: screen, options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: NSNumber(value: true),
            ])
        }
    }

    /// True if a wallpaper swap is waiting to be undone.
    public static var needsRestore: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Puts the original wallpaper back and deletes the backup. Safe to call when nothing is pending.
    /// Blocks the main thread for up to ~3 s while WallpaperAgent restarts (only after a swap).
    @MainActor
    @discardableResult
    public static func restoreWallpaper() -> Bool {
        guard let data = try? Data(contentsOf: backupURL),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return false }
        let fm = FileManager.default
        let photo = currentPhotoPaths()
        if restoreStore(expectingGoneFrom: photo) {
            try? fm.removeItem(at: storeCopyURL)
            try? fm.removeItem(at: backupURL)
            return true
        }
        // Fallback: per-screen image files.
        var ok = true
        for screen in NSScreen.screens {
            let entry = backup.entries.first { $0.screenID == screen.displayID } ?? backup.entries.first
            guard let entry else { continue }
            var opts: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let s = entry.scaling { opts[.imageScaling] = NSNumber(value: s) }
            if let c = entry.allowClipping { opts[.allowClipping] = NSNumber(value: c) }
            do { try NSWorkspace.shared.setDesktopImageURL(entry.url, for: screen, options: opts) } catch { ok = false }
        }
        if ok {
            try? fm.removeItem(at: storeCopyURL)
            try? fm.removeItem(at: backupURL)
        }
        return ok
    }

    /// The intruder photo(s) currently on screen, as paths.
    @MainActor
    private static func currentPhotoPaths() -> Set<String> {
        Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path }
            .filter { $0.hasPrefix(directory.standardizedFileURL.path + "/") })
    }

    /// Puts the store copy back and restarts WallpaperAgent. True once no screen shows the intruder photo.
    @MainActor
    private static func restoreStore(expectingGoneFrom photo: Set<String>) -> Bool {
        guard WallpaperStore.isUsable(at: storeCopyURL),
              let copy = try? Data(contentsOf: storeCopyURL) else { return false }
        do { try copy.write(to: systemStoreURL, options: .atomic) } catch { return false }
        guard WallpaperStore.restartAgent() else { return false }
        // The agent reloads within ~1 s. Confirm the photo is gone before trusting it.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if currentPhotoPaths().isDisjoint(with: photo) { return true }
        } while Date() < deadline
        return false
    }
}

/// macOS's wallpaper store file and the agent that owns it.
enum WallpaperStore {
    /// A readable property list with the top-level keys macOS 14–26 use. Anything else is left alone.
    static func isUsable(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count < 16 << 20,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["AllSpacesAndDisplays"] != nil || plist["Displays"] != nil || plist["SystemDefault"] != nil
    }

    /// WallpaperAgent reads the store only at launch; launchd restarts it right away when it exits.
    static func restartAgent() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["WallpaperAgent"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
