import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import MogCore

/// What happened in one analyzed frame of a watch session. Delivered on the camera queue.
public struct WatchTick {
    public let faces: [AnalyzedFace]
    /// Owner / stranger / unsure label per face (nil for faces that couldn't be identified).
    public let labels: [(MatchThresholds.Label, Float)?]
    public let observation: Observation
    public let action: GuardAction
    public let state: GuardState
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
                armDelay: TimeInterval, analyzer: FaceAnalyzer, camera: Camera = Camera()) {
        self.profile = profile
        self.thresholds = thresholds
        self.dryRun = dryRun
        self.analyzer = analyzer
        self.camera = camera
        self.guardian = Guard(grace: grace)
        self.armAt = Date().addingTimeInterval(armDelay)
    }

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
        if guardian.state == .off && Date() >= armAt { guardian.arm() }

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
        let action = guardian.observe(obs, at: now)
        let stateBefore = guardian.state
        let left = guardian.remaining(at: now).map {
            Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
        }

        var locked = false
        var photo: Data?
        if action == .lock {
            if capturePhoto { photo = Self.jpeg(from: frame) }
            if dryRun {
                guardian.arm()  // keep demonstrating; nothing is locked
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
                          state: stateBefore, secondsLeft: left, locked: locked, intruderJPEG: photo))
        if locked { camera.onFrame = nil }
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
