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
    private let quitItem = NSMenuItem(title: "Quit Mog", action: #selector(requestQuit), keyEquivalent: "q")
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
    /// When Turn Off / Quit was last refused (owner not in view). Cleared on unlock.
    private var refusedAt: Date?

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
            quitItem,
        ]
        statusItem.menu = menu
        quitItem.target = self

        do { embedder = try FaceEmbedder() } catch { fatalSetup("\(error)") }
        // A previous lock swapped the wallpaper and Mog quit before you unlocked: put it back.
        if IntruderPhoto.needsRestore && !ScreenLock.isScreenLocked { IntruderPhoto.restoreWallpaper() }
        refresh()

        // After the Mac unlocks, the guard stays off by design. Remind rather than silently re-arm.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        // Test hook: MOG_AUTOSTART=1 turns the guard on at launch (used by the gate test).
        if ProcessInfo.processInfo.environment["MOG_AUTOSTART"] == "1" { toggle() }
    }

    func applicationWillTerminate(_ note: Notification) {
        watch?.stop()
        enrollSession?.stop()
        if IntruderPhoto.needsRestore && !ScreenLock.isScreenLocked { IntruderPhoto.restoreWallpaper() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: Actions

    @objc private func toggle() {
        if watch != nil {
            guard ownerApproves() else { return }
            stopWatching(reason: "Off")
            return
        }
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
            // While guarding, show in the Dock too: right-click there reaches Turn Off / Quit even when
            // the menu-bar icon is hidden behind the notch or other items.
            NSApp.setActivationPolicy(.regular)
        } catch {
            alert("Mog can't start watching", "\(error)")
        }
        refresh()
    }

    @objc private func enroll() {
        guard let embedder else { return }
        guard ownerApproves() else { return }
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
        guard ownerApproves() else { return }
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
        refusedAt = nil
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
        NSApp.setActivationPolicy(.accessory)
        refresh()
    }

    // MARK: Owner gate

    /// While watching, Turn Off and Quit only work with the owner in front of the camera.
    /// Anyone else trying gets the Mac locked instead (and Mog switches off, as after any lock).
    /// Returns true if the action may go ahead.
    private func ownerApproves() -> Bool {
        // A refused attempt locked the Mac a moment ago; macOS may re-ask right away. Keep refusing
        // until someone unlocks, so the refusal can't be turned into a quit by asking twice.
        if refusedAt.map({ Date().timeIntervalSince($0) < 5 }) == true { return false }
        guard let watch else { return true }
        if watch.ownerSeen() { return true }
        refusedAt = Date()
        warning.hide()
        let locked = watch.lockNow()
        self.watch = nil
        NSApp.setActivationPolicy(.accessory)
        lastDetail = locked ? "Locked: you weren't in view when Mog was switched off." : "Lock failed. Off."
        refresh()
        if !locked { alert("Mog could not lock the screen", "The macOS lock call failed.") }
        return false
    }

    @objc private func requestQuit() {
        guard ownerApproves() else { return }
        NSApp.terminate(nil)
    }

    /// ⌘Q, Dock → Quit, logout and shutdown all come here. Logout/shutdown/restart are always allowed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The quit Apple Event carries its reason in the 'why?' parameter (kAEQuitReason).
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemQuit = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                          kAERestart, kAEShutDown].map { OSType($0) }
        if let reason, systemQuit.contains(reason) { return .terminateNow }
        return ownerApproves() ? .terminateNow : .terminateCancel
    }

    // MARK: Dock menu (right-click the Dock icon while watching)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dock = NSMenu()
        let status = NSMenuItem(title: detailLine.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        dock.addItem(status)
        dock.addItem(.separator())
        let toggle = NSMenuItem(title: watch != nil ? "Turn Off" : "Turn On", action: #selector(self.toggle),
                                keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = enrollSession == nil
        dock.addItem(toggle)
        // macOS adds its own Quit below; that goes through applicationShouldTerminate, same gate.
        return dock
    }

    /// Clicking the Dock icon opens the menu-bar menu, since Mog has no window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
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
