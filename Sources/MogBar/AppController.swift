import AppKit
import AVFoundation
import MogCore
import MogEngine

/// Menu-bar front end. All decisions come from MogEngine's WatchSession/EnrollSession,
/// the same code `mog watch` / `mog enroll` run.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    private let enrollItem = NSMenuItem(title: "", action: #selector(enroll), keyEquivalent: "")
    private let forgetItem = NSMenuItem(title: "Forget My Face", action: #selector(forget), keyEquivalent: "")
    private let photoItem = NSMenuItem(title: "Show Intruder Photo on Lock Screen", action: #selector(togglePhoto),
                                       keyEquivalent: "")
    private let inputItem = NSMenuItem(title: "Lock on Typing When Nobody’s There", action: #selector(toggleInput),
                                       keyEquivalent: "")
    private let intrudersItem = NSMenuItem(title: "Open Intruder Photos", action: #selector(openIntruders),
                                           keyEquivalent: "")
    private static let photoDefaultsKey = "showIntruderPhoto"
    private static let inputDefaultsKey = "lockOnUnseenInput"
    private var photoOnLock: Bool {
        get { UserDefaults.standard.bool(forKey: Self.photoDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.photoDefaultsKey) }
    }
    /// On unless the user turned it off.
    private var inputLock: Bool {
        get { UserDefaults.standard.object(forKey: Self.inputDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.inputDefaultsKey) }
    }

    private var embedder: FaceEmbedder?
    private var watch: WatchSession?
    private var enrollSession: EnrollSession?
    private var enrollWindow: EnrollWindow?
    private let warning = WarningPanel()
    private var lastDetail = ""

    private var profile: Profile? {
        guard let p = try? ProfileStore.load(), (try? p.validate(expectedModel: FaceEmbedder.modelID)) != nil
        else { return nil }
        return p
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for item in [statusLine, detailLine] { item.isEnabled = false }
        for item in [toggleItem, enrollItem, forgetItem, inputItem, photoItem, intrudersItem] { item.target = self }
        inputItem.toolTip = "A key press or click while nobody is in front of the camera locks the Mac, "
            + "once you've been away for 5 seconds."
        menu.autoenablesItems = false
        menu.delegate = self
        menu.items = [
            statusLine, detailLine, .separator(),
            toggleItem, .separator(),
            inputItem, photoItem, intrudersItem, .separator(),
            enrollItem, forgetItem, .separator(),
            NSMenuItem(title: "Quit Mog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        statusItem.menu = menu

        do { embedder = try FaceEmbedder() } catch { fatalSetup("\(error)") }
        // A previous lock swapped the wallpaper and Mog quit before you unlocked: put it back.
        if IntruderPhoto.needsRestore && !ScreenLock.isScreenLocked { IntruderPhoto.restoreWallpaper() }
        refresh()

        // After the Mac unlocks, the guard stays off by design. Remind rather than silently re-arm.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        watch?.stop()
        enrollSession?.stop()
        if IntruderPhoto.needsRestore && !ScreenLock.isScreenLocked { IntruderPhoto.restoreWallpaper() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: Actions

    @objc private func toggle() {
        if watch != nil { stopWatching(reason: "Off"); return }
        guard let profile else { enroll(); return }
        guard let embedder else { return }
        let session = WatchSession(profile: profile, thresholds: profile.thresholds, grace: Guard.defaultGrace,
                                   dryRun: false, armDelay: 3, inputLock: inputLock,
                                   analyzer: FaceAnalyzer(embedder: embedder))
        session.capturePhoto = photoOnLock
        if photoOnLock {
            session.beforeLock = { jpeg in
                guard let jpeg else { return }
                MainActor.assumeIsolated {
                    do { try IntruderPhoto.showOnLockScreen(try IntruderPhoto.save(jpeg)) } catch {
                        NSLog("Mog: could not set intruder photo: \(error)")
                    }
                }
            }
        }
        session.onTick = { [weak self] tick in
            DispatchQueue.main.async { self?.handle(tick) }
        }
        do {
            try session.start()
            watch = session
            lastDetail = "Arming in 3 s…"
        } catch {
            alert("Mog can't start watching", "\(error)")
        }
        refresh()
    }

    @objc private func enroll() {
        guard let embedder else { return }
        stopWatching(reason: "Off")
        enrollSession?.stop()
        let session = EnrollSession(target: 12, threshold: 0.40, strangerBelow: nil,
                                    analyzer: FaceAnalyzer(embedder: embedder))
        let window = EnrollWindow(session: session.captureSession, target: session.target)
        window.onClose = { [weak self] in
            self?.enrollSession?.stop()
            self?.enrollSession = nil
            self?.enrollWindow = nil
            self?.refresh()
        }
        session.onEvent = { [weak window] event in
            DispatchQueue.main.async { window?.show(event) }
        }
        enrollSession = session
        enrollWindow = window
        window.present()
        do { try session.start() } catch { window.show(.failed("\(error)")) }
    }

    @objc private func forget() {
        stopWatching(reason: "Off")
        do { try ProfileStore.delete() } catch { alert("Could not delete profile", "\(error)") }
        refresh()
    }

    @objc private func togglePhoto() {
        photoOnLock.toggle()
        if watch != nil { lastDetail = "Turn Mog off and on for this to take effect" }
        refresh()
    }

    @objc private func toggleInput() {
        inputLock.toggle()
        if watch != nil { lastDetail = "Turn Mog off and on for this to take effect" }
        refresh()
    }

    @objc private func openIntruders() {
        try? FileManager.default.createDirectory(at: IntruderPhoto.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(IntruderPhoto.directory)
    }

    @objc private func screenUnlocked() {
        let restored = IntruderPhoto.needsRestore && IntruderPhoto.restoreWallpaper()
        if watch == nil && profile != nil {
            lastDetail = restored
                ? "Welcome back. Intruder photo saved; wallpaper restored. Mog is off."
                : "Welcome back. Mog is off; turn it on again when you leave."
        }
        refresh()
    }

    // MARK: Watch updates

    private func handle(_ tick: WatchTick) {
        guard watch != nil else { return }
        switch tick.action {
        case .lock:
            warning.hide()
            stopWatching(reason: tick.locked ? "Locked the screen. Off." : "Lock failed. Off.")
            if !tick.locked { alert("Mog could not lock the screen", "The macOS lock call failed.") }
            return
        case .cancelWarning:
            warning.hide()
        case .startWarning, .none:
            if let left = tick.secondsLeft { warning.show(secondsLeft: left, reason: tick.reason ?? .stranger) }
        }

        let labels = tick.labels.compactMap { $0 }
        if case .off = tick.state {
            lastDetail = "Arming…"
        } else if let left = tick.secondsLeft {
            let what = tick.reason == .unseenInput ? "Typing with nobody in view" : "Stranger in view"
            lastDetail = String(format: "%@. Locking in %.0f s", what, left.rounded(.up))
        } else if labels.contains(where: { $0.0 == .owner }) {
            lastDetail = String(format: "You're here (match %.2f)", labels.map(\.1).max() ?? 0)
        } else if tick.faces.isEmpty {
            lastDetail = "Nobody in view"
        } else {
            lastDetail = "Face not clear enough to identify"
        }
        refresh()
    }

    private func stopWatching(reason: String) {
        watch?.stop()
        watch = nil
        warning.hide()
        lastDetail = reason
        refresh()
    }

    // MARK: UI

    private func refresh() {
        let hasProfile = profile != nil
        let watching = watch != nil
        let warningNow = warning.isVisible

        let symbol = warningNow ? "exclamationmark.shield.fill" : watching ? "eye.fill" : "eye.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mog")
        image?.isTemplate = !warningNow
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = warningNow ? .systemRed : nil

        statusLine.title = watching ? "Mog is watching" : hasProfile ? "Mog is off" : "Mog: no face enrolled"
        detailLine.title = lastDetail.isEmpty ? (hasProfile ? "Turn on before you step away" : "Enroll your face first") : lastDetail
        toggleItem.title = watching ? "Turn Off" : "Turn On"
        toggleItem.isEnabled = enrollSession == nil
        enrollItem.title = hasProfile ? "Re-enroll My Face…" : "Enroll My Face…"
        enrollItem.isEnabled = enrollSession == nil
        forgetItem.isHidden = !hasProfile
        photoItem.state = photoOnLock ? .on : .off
        inputItem.state = inputLock ? .on : .off
        intrudersItem.isHidden = IntruderPhoto.all().isEmpty
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func fatalSetup(_ message: String) -> Never {
        alert("Mog can't start", message)
        exit(1)
    }
}
