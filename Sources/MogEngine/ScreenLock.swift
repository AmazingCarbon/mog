import CoreGraphics
import Darwin
import Foundation

/// Screen lock via the same private call the Control Strip "Lock Screen" button uses
/// (login.framework `SACLockScreenImmediate`). No Accessibility or Automation permission needed.
/// Private API: fine for a personal tool, not App Store material.
public enum ScreenLock {
    private static let path = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    private typealias LockFn = @convention(c) () -> Int32

    public static var isAvailable: Bool { symbol() != nil }

    /// True while the login window / lock screen is in front.
    public static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    @discardableResult
    public static func lock() -> Bool {
        guard let sym = symbol() else { return false }
        _ = unsafeBitCast(sym, to: LockFn.self)()
        return true
    }

    private static func symbol() -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        return dlsym(handle, "SACLockScreenImmediate")
    }
}
