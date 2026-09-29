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
    private let stealthItem = NSMenuItem(title: "Stealth Mode (Camera Off Until Touched)", action: #selector(toggleStealth),
                                         keyEquivalent: "")
    private let intrudersItem = NSMenuItem(title: "Open Intruder Photos", action: #selector(openIntruders),
                                           keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates),
                                        keyEquivalent: "")
    /// Set once a check finds a newer version; the menu item then offers to install it.
    private var availableUpdate: String?
    private var checkingForUpdates = false
    private static let photoDefaultsKey = "showIntruderPhoto"
    private static let inputDefaultsKey = "lockOnUnseenInput"
    private static let stealthDefaultsKey = "stealthMode"
    private var stealthMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.stealthDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.stealthDefaultsKey) }
    }
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
    private var stealth: StealthSession?
    /// Guarding in either mode.
    private var guarding: Bool { watch != nil || stealth != nil }
    /// A stealth owner check for Turn Off / Quit is running; further requests wait for it.
    private var gatePending = false
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
        for item in [toggleItem, enrollItem, forgetItem, inputItem, stealthItem, photoItem, intrudersItem, updateItem] {
            item.target = self
        }
        inputItem.toolTip = "Any key press, click or trackpad touch while nobody is in front of the camera "
            + "locks the Mac at once."
        stealthItem.toolTip = "The camera (and its green light) stays off until someone types, clicks or touches "
            + "the trackpad. Then Mog looks once: you → camera off; anyone else, or nobody, → locks at once."
        menu.autoenablesItems = false
        menu.delegate = self
        menu.items = [
            statusLine, detailLine, .separator(),
            toggleItem, .separator(),
            stealthItem, inputItem, photoItem, intrudersItem, .separator(),
            enrollItem, forgetItem, .separator(),
            updateItem, quitItem,
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
        stealth?.stop()
        enrollSession?.stop()
        if IntruderPhoto.needsRestore && !ScreenLock.isScreenLocked { IntruderPhoto.restoreWallpaper() }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // MARK: Actions

    @objc private func toggle() {
        if guarding {
            withOwner { [weak self] in self?.stopWatching(reason: "Off") }
            return
        }
        guard let profile else { enroll(); return }
        guard let embedder else { return }
        if stealthMode { return startStealth(profile: profile, embedder: embedder) }
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

    private func startStealth(profile: Profile, embedder: FaceEmbedder) {
        let session = StealthSession(profile: profile, thresholds: profile.thresholds, dryRun: false, armDelay: 3,
                                     analyzer: FaceAnalyzer(embedder: embedder))
        session.capturePhoto = photoOnLock
        session.beforeLock = beforeLockHandler()
        session.onTick = { [weak self] tick in
            DispatchQueue.main.async { self?.handle(tick) }
        }
        do {
            try session.start()
            stealth = session
            lastDetail = "Arming in 3 s…"
            NSApp.setActivationPolicy(.regular)
        } catch {
            alert("Mog can't start watching", "\(error)")
        }
        refresh()
    }

    private func beforeLockHandler() -> ((Data?) -> Void)? {
        guard photoOnLock else { return nil }
        return { jpeg in
            guard let jpeg else { return }
            MainActor.assumeIsolated {
                do { try IntruderPhoto.showOnLockScreen(try IntruderPhoto.save(jpeg)) } catch {
                    NSLog("Mog: could not set intruder photo: \(error)")
                }
            }
        }
    }

    @objc private func enroll() {
        guard let embedder else { return }
        withOwner { [weak self] in self?.startEnroll(embedder) }
    }

    private func startEnroll(_ embedder: FaceEmbedder) {
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
        withOwner { [weak self] in
            self?.stopWatching(reason: "Off")
            do { try ProfileStore.delete() } catch { self?.alert("Could not delete profile", "\(error)") }
            self?.refresh()
        }
    }

    @objc private func togglePhoto() {
        photoOnLock.toggle()
        if guarding { lastDetail = "Turn Mog off and on for this to take effect" }
        refresh()
    }

    @objc private func toggleInput() {
        inputLock.toggle()
        if guarding { lastDetail = "Turn Mog off and on for this to take effect" }
        refresh()
    }

    @objc private func toggleStealth() {
        stealthMode.toggle()
        if guarding { lastDetail = "Turn Mog off and on for this to take effect" }
        refresh()
    }

    // MARK: Updates

    /// Checks GitHub for a newer Homebrew release, only when clicked. If one is waiting from an earlier
    /// check, offers to install it instead.
    @objc private func checkForUpdates() {
        if let latest = availableUpdate { return offerUpdate(latest) }
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        refresh()
        UpdateChecker.check { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkingForUpdates = false
                switch result {
                case .success(.available(let latest, _)):
                    self.availableUpdate = latest
                    self.refresh()
                    self.offerUpdate(latest)
                case .success(.upToDate(let current)):
                    self.refresh()
                    self.alert("Mog is up to date", "You have the latest version, \(current).")
                case .failure(let error):
                    self.refresh()
                    self.alert("Couldn't check for updates", "Mog \(error).")
                }
            }
        }
    }

    private func offerUpdate(_ latest: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Mog \(latest) is available"
        a.informativeText = "You have \(MogInfo.version). Updating opens Terminal and runs Homebrew there "
            + "(it builds from source, about a minute). Mog quits for the update and reopens when it's done."
        a.addButton(withTitle: "Update in Terminal")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Updating quits Mog: while guarding, that needs the owner, like any other quit.
        withOwner { [weak self] in self?.runUpdate() }
    }

    private func runUpdate() {
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        do {
            let script = try UpdateChecker.makeUpdateScript(appDirectory: appDir)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                return alert("Terminal not found", "Run this instead:\n\nbrew upgrade \(UpdateChecker.formulaName) && mog install-app")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let error {
                            self?.alert("Couldn't open Terminal", "\(error.localizedDescription)")
                            return
                        }
                        // Quit so the reinstall can replace Mog.app; the script reopens it.
                        self?.stopWatching(reason: "Updating…")
                        self?.quitApproved = true
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            alert("Couldn't start the update", "\(error)")
        }
    }

    @objc private func openIntruders() {
        try? FileManager.default.createDirectory(at: IntruderPhoto.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(IntruderPhoto.directory)
    }

    @objc private func screenUnlocked() {
        refusedAt = nil
        let restored = IntruderPhoto.needsRestore && IntruderPhoto.restoreWallpaper()
        if !guarding && profile != nil {
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
            let why = tick.reason == .unseenInput ? "Touched with nobody in view" : "Stranger in view"
            stopWatching(reason: tick.locked ? "\(why). Locked. Off." : "Lock failed. Off.")
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

    // MARK: Stealth updates

    private func handle(_ tick: StealthTick) {
        guard stealth != nil else { return }
        switch tick.action {
        case .lock(let reason):
            let what = reason == .stranger ? "Stranger touched the Mac" : "Touched while you weren't there"
            stopWatching(reason: tick.locked ? "\(what). Locked. Off." : "Lock failed. Off.")
            if !tick.locked { alert("Mog could not lock the screen", "The macOS lock call failed.") }
            return
        case .startCheck:
            lastDetail = "Touch detected, checking…"
        case .verified:
            lastDetail = String(format: "You're here (match %.2f). Camera off",
                                tick.labels.compactMap { $0?.1 }.max() ?? 0)
        case .trustExpired:
            lastDetail = "Camera off. Next touch will be checked"
        case .none:
            if tick.observation == nil { lastDetail = "Camera off. Next touch will be checked" }
        }
        refresh()
    }

    private func stopWatching(reason: String) {
        watch?.stop()
        watch = nil
        stealth?.stop()
        stealth = nil
        warning.hide()
        lastDetail = reason
        NSApp.setActivationPolicy(.accessory)
        refresh()
    }

    // MARK: Owner gate

    /// While guarding, Turn Off, Quit, Re-enroll and Forget only work with the owner in front of the camera.
    /// Anyone else trying gets the Mac locked instead (and Mog switches off, as after any lock).
    /// In stealth mode the camera is off, so this runs a quick check first; `action` runs if it passes.
    private func withOwner(_ action: @escaping () -> Void) {
        if refusedRecently { return }
        if let stealth {
            guard !gatePending else { return }
            gatePending = true
            lastDetail = "Checking it's you…"
            refresh()
            stealth.verifyOwner { [weak self] ok in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.gatePending = false
                    if ok { return action() }
                    // The check itself locked the Mac (or the screen was already locked).
                    self.refusedAt = Date()
                    self.warning.hide()
                    self.stopWatching(reason: "Locked: you weren't in view when Mog was switched off.")
                }
            }
            return
        }
        if ownerApproves() { action() }
    }

    /// A refused attempt locked the Mac a moment ago; macOS may re-ask right away. Keep refusing
    /// until someone unlocks, so the refusal can't be turned into a quit by asking twice.
    private var refusedRecently: Bool {
        refusedAt.map { Date().timeIntervalSince($0) < 5 } == true
    }

    /// Webcam-mode gate (camera already on): answers immediately.
    /// Returns true if the action may go ahead.
    private func ownerApproves() -> Bool {
        if refusedRecently { return false }
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
        withOwner { [weak self] in
            self?.quitApproved = true  // already checked: don't check again in applicationShouldTerminate
            NSApp.terminate(nil)
        }
    }

    /// Set while a quit that passed the stealth owner check is going through.
    private var quitApproved = false

    /// ⌘Q, Dock → Quit, logout and shutdown all come here. Logout/shutdown/restart are always allowed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The quit Apple Event carries its reason in the 'why?' parameter (kAEQuitReason).
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemQuit = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog,
                          kAERestart, kAEShutDown].map { OSType($0) }
        if let reason, systemQuit.contains(reason) { return .terminateNow }
        if quitApproved || !guarding { return .terminateNow }
        if stealth != nil {
            // Camera is off: check first, then quit for real if it's the owner.
            withOwner { [weak self] in
                self?.quitApproved = true
                NSApp.terminate(nil)
            }
            return .terminateCancel
        }
        return ownerApproves() ? .terminateNow : .terminateCancel
    }

    // MARK: Dock menu (right-click the Dock icon while watching)

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dock = NSMenu()
        let status = NSMenuItem(title: detailLine.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        dock.addItem(status)
        dock.addItem(.separator())
        let toggle = NSMenuItem(title: guarding ? "Turn Off" : "Turn On", action: #selector(self.toggle),
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
        let watching = guarding
        let warningNow = warning.isVisible

        let symbol = warningNow ? "exclamationmark.shield.fill"
            : stealth != nil ? "eye.circle" : watching ? "eye.fill" : "eye.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mog")
        image?.isTemplate = !warningNow
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = warningNow ? .systemRed : nil

        statusLine.title = stealth != nil ? "Mog is watching (stealth)"
            : watching ? "Mog is watching" : hasProfile ? "Mog is off" : "Mog: no face enrolled"
        detailLine.title = lastDetail.isEmpty ? (hasProfile ? "Turn on before you step away" : "Enroll your face first") : lastDetail
        toggleItem.title = watching ? "Turn Off" : "Turn On"
        toggleItem.isEnabled = enrollSession == nil
        enrollItem.title = hasProfile ? "Re-enroll My Face…" : "Enroll My Face…"
        enrollItem.isEnabled = enrollSession == nil
        forgetItem.isHidden = !hasProfile
        photoItem.state = photoOnLock ? .on : .off
        inputItem.state = inputLock ? .on : .off
        // The typing rule is built into stealth mode, so its own switch doesn't apply there.
        inputItem.isEnabled = !stealthMode
        stealthItem.state = stealthMode ? .on : .off
        intrudersItem.isHidden = IntruderPhoto.all().isEmpty
        updateItem.title = checkingForUpdates ? "Checking for Updates…"
            : availableUpdate.map { "Update Available: \($0)…" } ?? "Check for Updates…"
        updateItem.isEnabled = !checkingForUpdates && enrollSession == nil
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
