import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import MogCore

/// When the last key press or mouse click happened, from the system's own idle counters.
/// Reads timestamps only, never which key: no Input Monitoring or Accessibility permission needed.
public enum InputActivity {
    private static let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// Seconds since the most recent key press, modifier change or mouse click.
    /// Mouse movement and scrolling don't count: a bump or a cat shouldn't lock the Mac.
    public static var secondsSinceLastInput: Double {
        types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    /// The same, as an instant on the Guard's clock.
    public static func lastInput(now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        instant(secondsAgo: secondsSinceLastInput, now: now)
    }

    /// Every kind of touch of the keyboard, mouse or trackpad, listed explicitly rather than via
    /// `kCGAnyInputEventType`, so the set is exactly what the docs and tests describe.
    private static let touchTypes: [CGEventType] = types + [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ] + [29].compactMap { CGEventType(rawValue: $0) }  // 29 = NSEventTypeGesture (trackpad pinch, swipe…)

    /// Seconds since any touch of the keyboard, mouse or trackpad, including pointer movement and
    /// scrolling. Stealth mode uses this: there, touching the trackpad is exactly what should wake
    /// the camera.
    public static var secondsSinceAnyInput: Double {
        touchTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    public static func lastAnyInput(now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        instant(secondsAgo: secondsSinceAnyInput, now: now)
    }

    private static func instant(secondsAgo s: Double, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard s.isFinite, s >= 0, s < 7 * 24 * 3600 else { return nil }
        return now - .microseconds(Int(s * 1_000_000))
    }
}

/// What happened in one analyzed frame of a watch session. Delivered on the camera queue.
public struct WatchTick {
    public let faces: [AnalyzedFace]
    /// Owner / stranger / unsure label per face (nil for faces that couldn't be identified).
    public let labels: [(MatchThresholds.Label, Float)?]
    public let observation: Observation
    public let action: GuardAction
    public let state: GuardState
    /// Why the countdown is running (nil when not warning).
    public let reason: WarningReason?
    /// Seconds until lock while warning.
    public let secondsLeft: Double?
    /// True if this tick requested the real screen lock.
    public let locked: Bool
    /// JPEG of the frame that triggered the lock (only when `capturePhoto` is on and this tick locked
    /// or would have locked in a dry run).
    public let intruderJPEG: Data?
}

/// The guard loop shared by `mog watch`, `mog test` and the menu-bar app:
/// camera → faces → owner/stranger → Guard state machine → (optionally) screen lock.
public final class WatchSession {
    /// Converts a camera frame to JPEG. Call on the camera queue, while the frame is still valid.
    public static func jpeg(from frame: CVPixelBuffer) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().jpegRepresentation(
            of: CIImage(cvPixelBuffer: frame), colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }

    public let profile: Profile
    public let thresholds: MatchThresholds
    public let dryRun: Bool
    /// Keep a JPEG of the frame that triggered the lock (see WatchTick.intruderJPEG).
    public var capturePhoto = false
    /// Called on the camera queue with the intruder photo right before the screen locks, so the
    /// caller can put it on the lock screen first. Must not block for long.
    public var beforeLock: ((Data?) -> Void)?
    public var onTick: ((WatchTick) -> Void)?

    private let analyzer: FaceAnalyzer
    private let camera: Camera
    private var guardian: Guard
    private let armAt: Date

    public init(profile: Profile, thresholds: MatchThresholds, grace: Duration, dryRun: Bool,
                armDelay: TimeInterval, inputLock: Bool = false, analyzer: FaceAnalyzer,
                camera: Camera = Camera()) {
        self.profile = profile
        self.thresholds = thresholds
        self.dryRun = dryRun
        self.analyzer = analyzer
        self.camera = camera
        self.guardian = Guard(grace: grace, inputLock: inputLock)
        self.armAt = Date().addingTimeInterval(armDelay)
    }

    public var inputLock: Bool { guardian.inputLock }

    /// True if the owner was in front of the camera within `window`. Used to gate Turn Off and Quit:
    /// while watching, only the owner can switch Mog off. Anyone else trying gets the Mac locked.
    /// Still arming (the first 3 s after Turn On) counts as allowed: nothing is guarded yet.
    public func ownerSeen(within window: Duration = WatchSession.ownerGateWindow) -> Bool {
        let now = ContinuousClock.now
        return queue.sync { guardian.state == .off || guardian.ownerSeen(within: window, at: now) }
    }

    public static let ownerGateWindow: Duration = .seconds(2)

    /// Locks the screen right now (Turn Off or Quit attempted without the owner in view).
    /// Disarms the guard first, so nothing re-locks afterwards. Returns true if the lock call succeeded.
    @discardableResult
    public func lockNow() -> Bool {
        queue.sync { guardian.disarm() }
        camera.stop()
        camera.onFrame = nil
        return dryRun ? false : ScreenLock.lock()
    }

    /// Guards `guardian`, which the camera queue mutates, against reads from the main thread.
    private let queue = DispatchQueue(label: "mog.watch.state")

    public func start() throws {
        if !dryRun && !ScreenLock.isAvailable { throw EngineError.lockUnavailable }
        camera.onFrame = { [weak self] frame in self?.process(frame) }
        try camera.start()
    }

    public func stop() {
        camera.stop()
        camera.onFrame = nil
    }

    private func process(_ frame: CVPixelBuffer) {
        // Never analyze behind the lock screen: no camera decisions, no re-locking.
        if ScreenLock.isScreenLocked { return }

        let faces = analyzer.analyze(frame)
        let labels: [(MatchThresholds.Label, Float)?] = faces.map { f in
            f.embedding.map { e in
                let s = Embedding.bestMatch(e, in: profile.samples)
                return (thresholds.label(s), s)
            }
        }
        let verdicts = zip(faces, labels).map { FaceVerdict(usable: $0.usable, similarity: $1?.1) }
        let obs = Classifier.observe(verdicts, thresholds: thresholds)
        let now = ContinuousClock.now
        let lastInput = guardian.inputLock ? InputActivity.lastInput(now: now) : nil
        let (action, stateBefore, reason, remaining): (GuardAction, GuardState, WarningReason?, Duration?) = queue.sync {
            if guardian.state == .off && Date() >= armAt { guardian.arm(at: now) }
            let a = guardian.observe(obs, at: now, lastInput: lastInput)
            return (a, guardian.state, guardian.warningReason, guardian.remaining(at: now))
        }
        let left = remaining.map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        }

        var locked = false
        var photo: Data?
        if action == .lock {
            if capturePhoto { photo = Self.jpeg(from: frame) }
            if dryRun {
                queue.sync { guardian.arm(at: .now) }  // keep demonstrating; nothing is locked
            } else {
                camera.stop()
                if let beforeLock {
                    // Wallpaper changes must happen on the main thread. Wait up to 1.5 s so the photo
                    // is in place when the lock screen appears, but never let it block the lock.
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { beforeLock(photo); done.signal() }
                    _ = done.wait(timeout: .now() + 1.5)
                }
                locked = ScreenLock.lock()
            }
        }
        onTick?(WatchTick(faces: faces, labels: labels, observation: obs, action: action,
                          state: stateBefore, reason: reason, secondsLeft: left, locked: locked,
                          intruderJPEG: photo))
        if locked { camera.onFrame = nil }
    }
}

/// What happened in stealth mode. Delivered on a private queue.
public struct StealthTick {
    public let action: StealthAction
    /// State after this tick.
    public let state: StealthState
    /// Faces in the analyzed frame (empty for input-only ticks).
    public let faces: [AnalyzedFace]
    public let labels: [(MatchThresholds.Label, Float)?]
    /// What the frame showed; nil for input-only ticks.
    public let observation: Observation?
    /// Seconds since the check began, for ticks during or ending a check.
    public let checkElapsed: Double?
    /// True if this tick requested the real screen lock.
    public let locked: Bool
    public let intruderJPEG: Data?
}

/// Stealth guard loop: camera off until someone touches the Mac, then a quick look (see `StealthGuard`).
/// Shared by `mog watch --stealth`, `mog test --stealth` and the menu-bar app.
public final class StealthSession {
    public let profile: Profile
    public let thresholds: MatchThresholds
    public let dryRun: Bool
    public var capturePhoto = false
    /// Called right before the screen locks, with the photo (see WatchSession.beforeLock).
    public var beforeLock: ((Data?) -> Void)?
    public var onTick: ((StealthTick) -> Void)?

    private let analyzer: FaceAnalyzer
    private let camera: Camera
    private var guardian: StealthGuard
    private let armAt: ContinuousClock.Instant
    private var armed = false
    private var checkOnArm = false
    private var finished = false
    private var gateWaiters: [(Bool) -> Void] = []
    /// Protects everything above; never held while calling into the camera.
    private let lock = NSLock()
    private let pollQueue = DispatchQueue(label: "mog.stealth", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    public init(profile: Profile, thresholds: MatchThresholds, dryRun: Bool, armDelay: TimeInterval,
                idleAfter: Duration = StealthGuard.defaultIdleAfter,
                checkTimeout: Duration = StealthGuard.defaultCheckTimeout,
                analyzer: FaceAnalyzer, camera: Camera = Camera()) {
        self.profile = profile
        self.thresholds = thresholds
        self.dryRun = dryRun
        self.analyzer = analyzer
        self.camera = camera
        self.guardian = StealthGuard(idleAfter: idleAfter, checkTimeout: checkTimeout)
        self.armAt = .now + .milliseconds(Int(armDelay * 1000))
    }

    public var idleAfter: Duration { guardian.idleAfter }
    public var recheckAfter: Duration { guardian.recheckAfter }
    public var checkTimeout: Duration { guardian.checkTimeout }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public func start() throws {
        if !dryRun && !ScreenLock.isAvailable { throw EngineError.lockUnavailable }
        try Camera.ensureAccess()
        camera.interval = 0  // every frame: during a check, speed is the point
        camera.onFrame = { [weak self] frame in self?.process(frame) }
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        let waiters = locked { () -> [(Bool) -> Void] in
            finished = true
            guardian.disarm()
            defer { gateWaiters = [] }
            return gateWaiters
        }
        camera.stop()
        camera.onFrame = nil
        resolve(waiters, false)
    }

    /// Check once as soon as the guard arms, without waiting for input (`mog test --stealth`).
    public func checkWhenArmed() { locked { checkOnArm = true } }

    /// Owner gate for Turn Off / Quit / Re-enroll / Forget. `done(true)` if the camera saw the owner in
    /// the last `ownerGateWindow`, or does now within the check timeout. Otherwise the check locks the
    /// Mac and `done(false)`. Always called on the main queue.
    public func verifyOwner(_ done: @escaping (Bool) -> Void) {
        let now = ContinuousClock.now
        let (answer, start): (Bool?, Bool) = locked {
            if finished || !armed || !guardian.isArmed { return (true, false) }  // arming or over: nothing to guard
            if guardian.verified(within: WatchSession.ownerGateWindow, at: now) { return (true, false) }
            gateWaiters.append(done)
            return (nil, guardian.checkNow(at: now) == .startCheck)
        }
        if let answer { return DispatchQueue.main.async { done(answer) } }
        if start { pollQueue.async { [weak self] in self?.syncCamera() } }
    }

    // MARK: Loop

    private func poll() {
        let now = ContinuousClock.now
        if ScreenLock.isScreenLocked {
            // Locked by hand: camera off, and the password typed on the lock screen doesn't count.
            let waiters = locked { () -> [(Bool) -> Void] in
                guardian.pause(at: now)
                defer { gateWaiters = [] }
                return gateWaiters
            }
            syncCamera()
            resolve(waiters, false)
            return
        }
        let lastInput = InputActivity.lastAnyInput(now: now)
        let (action, before, state): (StealthAction, StealthState, StealthState) = locked {
            if finished { return (.none, guardian.state, guardian.state) }
            if !armed && now >= armAt {
                armed = true
                guardian.arm(at: now)
                if checkOnArm { return (guardian.checkNow(at: now), .idle, guardian.state) }
                return (.none, .off, guardian.state)
            }
            let before = guardian.state
            return (guardian.poll(lastInput: lastInput, at: now), before, guardian.state)
        }
        if before == .off && state == .idle {
            emit(StealthTick(action: .none, state: state, faces: [], labels: [], observation: nil,
                             checkElapsed: nil, locked: false, intruderJPEG: nil))
        }
        handle(action, before: before, state: state, now: now, frame: nil)
    }

    private func process(_ frame: CVPixelBuffer) {
        if ScreenLock.isScreenLocked || !locked({ guardian.isChecking }) { return }
        let faces = analyzer.analyze(frame)
        let labels: [(MatchThresholds.Label, Float)?] = faces.map { f in
            f.embedding.map { e in
                let s = Embedding.bestMatch(e, in: profile.samples)
                return (thresholds.label(s), s)
            }
        }
        let verdicts = zip(faces, labels).map { FaceVerdict(usable: $0.usable, similarity: $1?.1) }
        let obs = Classifier.observe(verdicts, thresholds: thresholds)
        let now = ContinuousClock.now
        let (action, before, state) = locked { () -> (StealthAction, StealthState, StealthState) in
            let before = guardian.state
            return (guardian.observe(obs, at: now), before, guardian.state)
        }
        handle(action, before: before, state: state, now: now, frame: frame, faces: faces, labels: labels, obs: obs)
    }

    private func handle(_ action: StealthAction, before: StealthState, state: StealthState,
                        now: ContinuousClock.Instant, frame: CVPixelBuffer?,
                        faces: [AnalyzedFace] = [], labels: [(MatchThresholds.Label, Float)?] = [],
                        obs: Observation? = nil) {
        var elapsed: Double?
        if case .checking(let since) = before {
            let d = (now - since).components
            elapsed = Double(d.seconds) + Double(d.attoseconds) / 1e18
        }
        var didLock = false
        var photo: Data?
        switch action {
        case .none:
            if obs == nil { return }  // nothing to report between frames
        case .startCheck, .trustExpired:
            syncCamera()
        case .verified:
            syncCamera()
            resolve(locked { defer { gateWaiters = [] }; return gateWaiters }, true)
        case .lock:
            syncCamera()
            if capturePhoto, let frame { photo = WatchSession.jpeg(from: frame) }
            let waiters = locked { () -> [(Bool) -> Void] in
                if dryRun { guardian.arm(at: now) } else { finished = true }  // dry run: keep demonstrating
                defer { gateWaiters = [] }
                return gateWaiters
            }
            if !dryRun {
                // `finished` stops the poll loop; stop() cancels the timer.
                if let beforeLock {
                    let done = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { beforeLock(photo); done.signal() }
                    _ = done.wait(timeout: .now() + 1.5)
                }
                didLock = ScreenLock.lock()
            }
            resolve(waiters, false)
        }
        emit(StealthTick(action: action, state: state, faces: faces, labels: labels, observation: obs,
                         checkElapsed: elapsed, locked: didLock, intruderJPEG: photo))
        if didLock { camera.onFrame = nil }
    }

    private func emit(_ tick: StealthTick) { onTick?(tick) }

    /// Camera on exactly while a check runs.
    private func syncCamera() {
        do {
            try camera.reconcile { [weak self] in self?.locked { self?.guardian.isChecking ?? false } ?? false }
        } catch {
            NSLog("Mog: camera: \(error)")
        }
    }

    private func resolve(_ waiters: [(Bool) -> Void], _ ok: Bool) {
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async { waiters.forEach { $0(ok) } }
    }
}

/// Progress of an enrollment. Delivered on the camera queue.
public enum EnrollEvent {
    case hint(String)
    case sample(count: Int, target: Int, face: AnalyzedFace)
    case finished(Profile, worstSelfMatch: Float)
    case failed(String)
}

/// Collects owner samples. Only accepts frames with exactly one usable face, and each new sample
/// must resemble the ones before, so a second person walking in can't poison the profile.
public final class EnrollSession {
    public let target: Int
    public var onEvent: ((EnrollEvent) -> Void)?

    private let analyzer: FaceAnalyzer
    private let camera: Camera
    private let threshold: Float
    private let strangerBelow: Float?
    private let timeout: TimeInterval
    private var samples: [[Float]] = []
    private var lastSampleAt = Date.distantPast
    private var lastHint = ""
    private var started = Date()
    private var done = false

    public init(target: Int, threshold: Float, strangerBelow: Float?, timeout: TimeInterval = 90,
                analyzer: FaceAnalyzer, camera: Camera = Camera()) {
        self.target = max(Profile.minSamples, target)
        self.threshold = threshold
        self.strangerBelow = strangerBelow
        self.timeout = timeout
        self.analyzer = analyzer
        self.camera = camera
    }

    /// The live camera session, for a preview layer.
    public var captureSession: AVCaptureSession { camera.captureSession }

    public func start() throws {
        started = Date()
        camera.onFrame = { [weak self] frame in self?.process(frame) }
        try camera.start()
    }

    public func stop() {
        done = true
        camera.stop()
        camera.onFrame = nil
    }

    private func hint(_ s: String) {
        guard s != lastHint else { return }
        lastHint = s
        onEvent?(.hint(s))
    }

    private func finish(_ event: EnrollEvent) {
        done = true
        camera.stop()
        onEvent?(event)
    }

    private func process(_ frame: CVPixelBuffer) {
        guard !done else { return }
        if Date().timeIntervalSince(started) > timeout {
            return finish(.failed("Timed out with \(samples.count)/\(target) samples. Try better light and face the camera."))
        }
        let faces = analyzer.analyze(frame)
        if faces.isEmpty { return hint("No face. Look at the camera.") }
        if faces.count > 1 { return hint("\(faces.count) faces. Enroll alone.") }
        let face = faces[0]
        guard let e = face.embedding else { return hint("Hold on: \(face.rejectReason ?? "unclear").") }
        guard Date().timeIntervalSince(lastSampleAt) >= 0.35 else { return }

        if !samples.isEmpty {
            let s = Embedding.bestMatch(e, in: samples)
            if s < 0.35 {
                return hint(String(format: "Rejected a sample (similarity %.2f). Is someone else in view?", s))
            }
        }
        samples.append(e)
        lastSampleAt = Date()
        lastHint = ""
        onEvent?(.sample(count: samples.count, target: target, face: face))

        guard samples.count >= target else { return }
        // Leave-one-out: how well each sample is recognized by the rest. Same person → high.
        let worst = samples.indices.map { i -> Float in
            var rest = samples; rest.remove(at: i)
            return Embedding.bestMatch(samples[i], in: rest)
        }.min() ?? 0
        let profile = Profile(model: FaceEmbedder.modelID, threshold: threshold,
                              strangerBelow: strangerBelow, samples: samples)
        do {
            try ProfileStore.save(profile)
            finish(.finished(profile, worstSelfMatch: worst))
        } catch {
            finish(.failed("Could not save profile: \(error)"))
        }
    }
}
