import AppKit
import AVFoundation
import Vision
import CoreVideo
import Foundation
import MogCore
import MogEngine

// Line-buffered stdout so logs show up live even when piped to a file or `tee`.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
mog — lock the Mac when someone else looks at it.

USAGE
  mog enroll [--samples N]        Record your face (look at the camera, move your head a little).
  mog test   [--grace S] [--photo]      Dry run: live log of every frame. NEVER locks.
  mog watch  [--grace S] [--photo] [-v] Guard for real. Locks once, then exits (no lock loops).
  mog lock-test                   Lock the screen in 3 seconds (checks the lock path).
  mog status                      Profile, model, camera, lock availability.
  mog probe                       8 s camera diagnostic: detection, alignment, embedding stability.
  mog forget                      Delete your enrolled face profile.
  mog intruders                   List saved intruder photos.
  mog restore-wallpaper           Put your original wallpaper back (if a swap is pending).
  mog install-app [--dir D]       Install the menu-bar app (Mog.app) into ~/Applications (or D).
  mog selftest                    Load the face model and run it once (no camera).
  mog version                     Print the version.

OPTIONS
  --grace S        Seconds a stranger must stay in view before lock (default 1).
  --photo          Save the intruder's photo and show it on the lock screen (as the wallpaper).
                   Your wallpaper comes back after you unlock. In `test`, only saves the photo.
  --threshold X    Similarity at or above X counts as you (default 0.40).
  --stranger X     Similarity below X counts as someone else (default 0.33). Between the two
                   is "unsure" and never starts a countdown.
  -v, --verbose    In watch mode, log every frame like `test` does.

Your profile is ~/.config/mog/profile.json (512 numbers per sample, no images).
"""

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func flag(_ names: String...) -> Bool {
    for n in names { if let i = args.firstIndex(of: n) { args.remove(at: i); return true } }
    return false
}
func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
    args.removeSubrange(i...(i + 1))
    return v
}

let verbose = flag("-v", "--verbose")
let photoOnLock = flag("--photo")
let graceSeconds = option("--grace") ?? 1
let thresholdOverride = option("--threshold").map(Float.init)
let strangerOverride = option("--stranger").map(Float.init)
let sampleTarget = Int(option("--samples") ?? 12)
let defaultThreshold: Float = 0.40

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mog: \(message)\n".utf8))
    exit(1)
}

// MARK: Logging

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
func stamp() -> String { clock.string(from: Date()) }

func describe(_ f: AnalyzedFace, thresholds: MatchThresholds, profile: Profile) -> String {
    guard let e = f.embedding else { return "unclear: \(f.rejectReason ?? "?")" }
    let s = Embedding.bestMatch(e, in: profile.samples)
    let label: String
    switch thresholds.label(s) {
    case .owner: label = "OWNER"
    case .stranger: label = "STRANGER"
    case .unsure: label = "unsure"
    }
    return String(format: "%@ %.2f", label, s)
}

// MARK: Engine setup

func loadEngine() -> (FaceAnalyzer, Camera) {
    let embedder: FaceEmbedder
    do { embedder = try FaceEmbedder() } catch { fail("\(error)") }
    return (FaceAnalyzer(embedder: embedder), Camera())
}

func loadProfile(required: Bool) -> Profile? {
    let p: Profile?
    do { p = try ProfileStore.load() } catch { fail("profile unreadable (\(error)). Run `mog forget` then `mog enroll`.") }
    guard let p else {
        if required { fail("no face enrolled. Run `mog enroll` first.") }
        return nil
    }
    do { try p.validate(expectedModel: FaceEmbedder.modelID) } catch {
        fail("\(error). Run `mog enroll`.")
    }
    return p
}

var interrupt: DispatchSourceSignal?
func onInterrupt(_ body: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    s.setEventHandler { body(); exit(0) }
    s.resume()
    interrupt = s
}

func startCamera(_ camera: Camera) {
    do { try camera.start() } catch { fail("\(error)") }
}

// MARK: Commands

func enroll() -> Never {
    let (analyzer, camera) = loadEngine()
    let threshold = thresholdOverride ?? defaultThreshold
    let session = EnrollSession(target: sampleTarget, threshold: threshold, strangerBelow: strangerOverride,
                                analyzer: analyzer, camera: camera)

    print("Enrolling. Sit alone in front of the camera, look at the screen,")
    print("and slowly move your head a little (left, right, up, down).")
    print("Collecting \(session.target) samples…\n")

    session.onEvent = { event in
        switch event {
        case .hint(let s):
            print("  \(stamp())  \(s)")
        case .sample(let n, let target, let face):
            print("  \(stamp())  sample \(n)/\(target)  (eyes \(Int(face.eyeDistance))px)")
        case .finished(let profile, let worst):
            print(String(format: "\nEnrolled %d samples. Self-match: worst %.2f, you ≥ %.2f.",
                         profile.samples.count, worst, profile.threshold))
            if worst < profile.threshold + 0.1 {
                print("Warning: some samples barely match each other. Re-enroll in better light for fewer false locks.")
            }
            print("Saved \(ProfileStore.defaultURL.path)")
            print("\nNext: `mog test`, a dry run that shows OWNER/STRANGER per frame and never locks.")
            exit(0)
        case .failed(let message):
            fail(message)
        }
    }

    onInterrupt { session.stop(); print("\ncancelled, nothing saved") }
    do { try session.start() } catch { fail("\(error)") }
    dispatchMain()
}

/// Shared by `test` (dry run) and `watch` (real).
func guardLoop(dryRun: Bool) -> Never {
    let profile = loadProfile(required: true)!
    let thresholds = MatchThresholds(
        owner: thresholdOverride ?? profile.threshold,
        stranger: strangerOverride ?? profile.thresholds.stranger)
    let (analyzer, camera) = loadEngine()
    let session = WatchSession(profile: profile, thresholds: thresholds,
                               grace: .milliseconds(Int(graceSeconds * 1000)), dryRun: dryRun,
                               armDelay: dryRun ? 0 : 3, analyzer: analyzer, camera: camera)
    let logEveryFrame = dryRun || verbose
    session.capturePhoto = photoOnLock
    MainActor.assumeIsolated { restorePendingWallpaper() }
    if photoOnLock && !dryRun {
        session.beforeLock = { jpeg in
            guard let jpeg else { return }
            MainActor.assumeIsolated {
                do {
                    let url = try IntruderPhoto.save(jpeg)
                    try IntruderPhoto.showOnLockScreen(url)
                    print("\(stamp())  intruder photo on lock screen: \(url.path)")
                } catch {
                    print("\(stamp())  could not set intruder photo: \(error)")
                }
            }
        }
    }

    print(dryRun
        ? "DRY RUN: will never lock. Ctrl-C to stop."
        : "WATCHING: will lock once when a stranger stays \(graceSeconds)s without you. Ctrl-C to stop.")
    print(String(format: "profile: %d samples, you ≥ %.2f, stranger < %.2f, grace %.1fs\n",
                 profile.samples.count, thresholds.owner, thresholds.stranger, graceSeconds))
    if !dryRun { print("arming in 3 s…") }

    var lastState = ""
    var lastHeartbeat = Date()
    var announcedArmed = false

    session.onTick = { tick in
        let faceText = tick.faces.isEmpty ? "-" : tick.faces.map { describe($0, thresholds: thresholds, profile: profile) }
            .joined(separator: ", ")
        let stateText: String
        switch tick.state {
        case .off: stateText = "off"
        case .watching: stateText = "watching"
        case .locked: stateText = "LOCK"
        case .warning: stateText = String(format: "WARNING lock in %.1fs", tick.secondsLeft ?? 0)
        }
        if !dryRun && !announcedArmed && tick.state != .off {
            announcedArmed = true
            print("\(stamp())  ARMED")
        }

        switch tick.action {
        case .startWarning:
            print("\u{7}\(stamp())  !!! STRANGER: \(faceText). Locking in \(graceSeconds)s unless you return.")
        case .cancelWarning:
            let ownerBack = tick.observation == .owner || tick.observation == .stranger(ownerAlsoPresent: true)
            print("\(stamp())  warning cancelled (\(ownerBack ? "owner back" : "stranger gone"))")
        case .lock:
            if dryRun {
                print("\(stamp())  >>> WOULD LOCK NOW (dry run), re-arming")
                if let jpeg = tick.intruderJPEG {
                    if let url = try? IntruderPhoto.save(jpeg) { print("\(stamp())  intruder photo saved: \(url.path)") }
                }
            } else {
                print("\(stamp())  >>> \(tick.locked ? "LOCKED" : "LOCK CALL FAILED")")
                print("Mog is now off. Run `mog watch` again to re-arm.")
                if IntruderPhoto.needsRestore {
                    // Stay alive until you unlock, then put your wallpaper back.
                    DispatchQueue.main.async { waitForUnlockThenRestore(exitCode: tick.locked ? 0 : 1) }
                    return
                }
                exit(tick.locked ? 0 : 1)
            }
        case .none:
            break
        }

        if logEveryFrame {
            print("\(stamp())  faces: \(faceText)  →  \(stateText)")
        } else if stateText != lastState || Date().timeIntervalSince(lastHeartbeat) > 30 {
            if !stateText.hasPrefix("WARNING") || !lastState.hasPrefix("WARNING") {
                print("\(stamp())  \(stateText)  (faces: \(faceText))")
            }
            lastHeartbeat = Date()
        }
        lastState = stateText
    }

    onInterrupt {
        session.stop()
        MainActor.assumeIsolated { restorePendingWallpaper() }
        print("\nstopped")
    }
    do { try session.start() } catch { fail("\(error)") }
    dispatchMain()
}

/// If an earlier run swapped the wallpaper and never restored it (crash, Ctrl-C while locked), undo it now.
@MainActor
func restorePendingWallpaper() {
    guard IntruderPhoto.needsRestore, !ScreenLock.isScreenLocked else { return }
    print(IntruderPhoto.restoreWallpaper() ? "restored your original wallpaper" : "could not restore wallpaper")
}

var unlockTimer: DispatchSourceTimer?
/// Polls the session lock state: once the lock screen has come and gone, restore the wallpaper and exit.
func waitForUnlockThenRestore(exitCode: Int32) {
    print("\(stamp())  waiting for you to unlock to restore your wallpaper…")
    var sawLocked = false
    let started = Date()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler {
        let locked = ScreenLock.isScreenLocked
        if locked { sawLocked = true }
        // If the lock screen never showed up within 10 s, don't leave the photo as the wallpaper.
        guard (sawLocked && !locked) || (!sawLocked && Date().timeIntervalSince(started) > 10) else { return }
        MainActor.assumeIsolated { _ = IntruderPhoto.restoreWallpaper() }
        print("\(stamp())  wallpaper restored")
        exit(exitCode)
    }
    t.resume()
    unlockTimer = t
}

func lockTest() -> Never {
    guard ScreenLock.isAvailable else { fail("macOS lock service unavailable on this system") }
    for i in stride(from: 3, to: 0, by: -1) { print("locking in \(i)…"); sleep(1) }
    print(ScreenLock.lock() ? "lock requested" : "lock call failed")
    exit(0)
}

func status() -> Never {
    let camera: String
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: camera = "allowed"
    case .notDetermined: camera = "not asked yet (first run will prompt)"
    default: camera = "DENIED — allow your terminal in System Settings → Privacy & Security → Camera"
    }
    print("camera:  \(camera)")
    print("lock:    \(ScreenLock.isAvailable ? "available" : "UNAVAILABLE")")
    do { print("model:   \(try FaceEmbedder.locate().path)") } catch { print("model:   MISSING — \(error)") }
    do {
        if let p = try ProfileStore.load() {
            let valid = (try? p.validate(expectedModel: FaceEmbedder.modelID)) != nil
            print(String(format: "profile: %d samples, you ≥ %.2f, stranger < %.2f, %@%@", p.samples.count,
                         p.thresholds.owner, p.thresholds.stranger,
                         ISO8601DateFormatter().string(from: p.createdAt), valid ? "" : "  (INVALID — re-enroll)"))
        } else {
            print("profile: none — run `mog enroll`")
        }
    } catch { print("profile: unreadable — \(error)") }
    exit(0)
}

/// Hidden diagnostic: checks alignment geometry and embedding stability on live frames.
func probe() -> Never {
    let (analyzer, camera) = loadEngine()
    var embeddings: [[Float]] = []
    var alignErrors: [Double] = []
    var frames = 0
    let seconds = 8.0
    let end = Date().addingTimeInterval(seconds)

    analyzer.onAligned = { crop in
        // Re-detect landmarks on the aligned crop; eyes should land on the ArcFace template.
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: crop, orientation: .up, options: [:]).perform([req])
        guard let o = req.results?.first, let lm = o.landmarks,
              let l = lm.leftEye?.pointsInImage(imageSize: CGSize(width: 112, height: 112)),
              let r = lm.rightEye?.pointsInImage(imageSize: CGSize(width: 112, height: 112)) else {
            alignErrors.append(.infinity); return
        }
        func c(_ p: [CGPoint]) -> (Double, Double) {
            (Double(p.map(\.x).reduce(0, +)) / Double(p.count), 112 - Double(p.map(\.y).reduce(0, +)) / Double(p.count))
        }
        let eyes = [c(l), c(r)].sorted { $0.0 < $1.0 }
        let t = [ArcFaceTemplate.eyeLeft, ArcFaceTemplate.eyeRight]
        let err = zip(eyes, t).map { hypot($0.0 - Double($1.x), $0.1 - Double($1.y)) }.max()!
        alignErrors.append(err)
    }

    camera.onFrame = { frame in
        frames += 1
        let found = analyzer.analyze(frame)
        if found.isEmpty { print("  frame \(frames): no face") }
        for f in found {
            if let e = f.embedding { embeddings.append(e) }
            else { print("  unclear: \(f.rejectReason ?? "?")") }
        }
        guard Date() >= end else { return }
        camera.stop()
        print("frames \(frames), embedded faces \(embeddings.count)")
        let finite = alignErrors.filter(\.isFinite).sorted()
        if !finite.isEmpty {
            print(String(format: "alignment: eye error vs template median %.1fpx, max %.1fpx (of 112), re-detect failures %d",
                         finite[finite.count / 2], finite.last!, alignErrors.count - finite.count))
        }
        if embeddings.count >= 2 {
            var sims: [Float] = []
            for i in 0..<embeddings.count { for j in (i + 1)..<embeddings.count {
                sims.append(Embedding.similarity(embeddings[i], embeddings[j])) } }
            sims.sort()
            print(String(format: "same-session similarity: min %.2f  median %.2f  max %.2f  (%d pairs)",
                         sims.first!, sims[sims.count / 2], sims.last!, sims.count))
        }
        exit(0)
    }
    startCamera(camera)
    dispatchMain()
}

/// Installs Mog.app. With Homebrew, MogBar sits next to `mog` in bin/ and the model in libexec/;
/// the app then points at the model instead of copying 125 MB.
func installApp() -> Never {
    // argv[0] is just "mog" when run from $PATH; ask the OS for the real path instead.
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let bar = exe.deletingLastPathComponent().appendingPathComponent("MogBar")
    guard FileManager.default.isExecutableFile(atPath: bar.path) else {
        fail("MogBar not found next to \(exe.path). Build it with `swift build -c release`.")
    }
    let model: URL
    do { model = try FaceEmbedder.locate() } catch { fail("\(error)") }
    var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    if let i = args.firstIndex(of: "--dir"), i + 1 < args.count {
        dir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = AppInstaller.locateIcon(near: exe)
        let r = try AppInstaller.install(bar: bar, model: model, icon: icon, into: dir, embedModel: flag("--embed-model"))
        // Nudge Finder/Dock to pick up the new icon instead of a cached blank one.
        NSWorkspace.shared.noteFileSystemChanged(r.app.path)
        print("installed \(r.app.path)")
        if icon == nil { print("note:     no AppIcon.icns found, installed without an icon") }
        print("model:    \(r.modelPath)")
        print("open it:  open \"\(r.app.path)\"")
    } catch { fail("\(error)") }
    exit(0)
}

func selftest() -> Never {
    do {
        let embedder = try FaceEmbedder()
        let n = try embedder.selfTest()
        print("ok: model loaded from \(embedder.modelURL.path), embedding size \(n)")
    } catch { fail("\(error)") }
    exit(0)
}

switch command {
case "version", "--version": print("mog \(MogInfo.version)")
case "selftest": selftest()
case "install-app": installApp()
case "compile-model":
    // Used by the Homebrew formula: mog compile-model <in.mlpackage> <out.mlmodelc>
    guard args.count == 2 else { fail("usage: mog compile-model <in.mlpackage> <out.mlmodelc>") }
    do { try FaceEmbedder.compile(URL(fileURLWithPath: args[0]), to: URL(fileURLWithPath: args[1])) } catch {
        fail("could not compile model: \(error)")
    }
    print("compiled \(args[1])")
case "probe": probe()
case "enroll": enroll()
case "test": guardLoop(dryRun: true)
case "watch": guardLoop(dryRun: false)
case "lock-test": lockTest()
case "status": status()
case "forget":
    do { try ProfileStore.delete() } catch { fail("\(error)") }
    print("profile deleted")
case "intruders":
    let photos = IntruderPhoto.all()
    if photos.isEmpty { print("no intruder photos (\(IntruderPhoto.directory.path))") }
    for url in photos { print(url.path) }
case "restore-wallpaper":
    MainActor.assumeIsolated {
        if !IntruderPhoto.needsRestore { print("nothing to restore") }
        else { print(IntruderPhoto.restoreWallpaper() ? "wallpaper restored" : "could not restore wallpaper") }
    }
case "help", "-h", "--help": print(usage)
default: fail("unknown command '\(command)'\n\n\(usage)")
}
