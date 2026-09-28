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
    @MainActor
    @discardableResult
    public static func restoreWallpaper() -> Bool {
        guard let data = try? Data(contentsOf: backupURL),
              let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return false }
        var ok = true
        for screen in NSScreen.screens {
            let entry = backup.entries.first { $0.screenID == screen.displayID } ?? backup.entries.first
            guard let entry else { continue }
            var opts: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let s = entry.scaling { opts[.imageScaling] = NSNumber(value: s) }
            if let c = entry.allowClipping { opts[.allowClipping] = NSNumber(value: c) }
            do { try NSWorkspace.shared.setDesktopImageURL(entry.url, for: screen, options: opts) } catch { ok = false }
        }
        if ok { try? FileManager.default.removeItem(at: backupURL) }
        return ok
    }
}

extension NSScreen {
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
