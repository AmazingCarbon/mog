import Foundation
import MogCore

// Dependency-free checks: `swift run MogChecks`. Exit code 1 on first failure.

var passed = 0
@MainActor
func check(_ ok: @autoclosure () -> Bool, _ name: String) {
    guard ok() else {
        FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
        exit(1)
    }
    passed += 1
    print("ok  \(name)")
}
func near(_ a: Float, _ b: Float, _ eps: Float = 1e-3) -> Bool { abs(a - b) <= eps }

let t0 = ContinuousClock.now
func at(_ s: Double) -> ContinuousClock.Instant { t0 + .milliseconds(Int(s * 1000)) }
let stranger = Observation.stranger(ownerAlsoPresent: false)
let strangerWithOwner = Observation.stranger(ownerAlsoPresent: true)

// MARK: Guard — the part that decides whether to lock.

do {
    var g = Guard(grace: .seconds(4))
    check(g.observe(stranger, at: at(0)) == .none, "unarmed guard ignores strangers")
    check(!g.isArmed, "guard starts disarmed")
}
do {
    var g = Guard(grace: .seconds(4)); g.arm()
    for s in stride(from: 0.0, through: 600.0, by: 0.25) { _ = g.observe(.empty, at: at(s)) }
    check(g.state == .watching, "empty room for 10 minutes never locks")
}
do {
    var g = Guard(grace: .seconds(4)); g.arm()
    for s in stride(from: 0.0, through: 60.0, by: 0.25) { _ = g.observe(.owner, at: at(s)) }
    check(g.state == .watching, "owner alone never locks")
}
do {
    var g = Guard(grace: .seconds(4)); g.arm()
    for s in stride(from: 0.0, through: 60.0, by: 0.25) { _ = g.observe(strangerWithOwner, at: at(s)) }
    check(g.state == .watching, "stranger over owner's shoulder never locks")
}
do {
    var g = Guard(grace: .seconds(4)); g.arm()
    check(g.observe(stranger, at: at(0)) == .startWarning, "stranger alone starts warning")
    check(g.observe(stranger, at: at(1)) == .none, "stranger frame 2")
    check(g.observe(stranger, at: at(3.9)) == .none, "no lock before grace")
    check(g.remaining(at: at(3)) == .seconds(1), "remaining time reported")
    check(g.observe(stranger, at: at(4.0)) == .lock, "lock at grace")
    check(g.state == .locked && !g.isArmed, "lock disarms guard")
    check(g.observe(stranger, at: at(10)) == .none, "no lock loop after locking")
}
do {
    var g = Guard(grace: .seconds(4)); g.arm()
    _ = g.observe(stranger, at: at(0))
    check(g.observe(.owner, at: at(2)) == .cancelWarning, "owner returning cancels warning")
    check(g.observe(stranger, at: at(3)) == .startWarning, "countdown restarts from zero")
    _ = g.observe(stranger, at: at(5))
    check(g.observe(stranger, at: at(6.9)) == .none, "restarted countdown not yet expired")
    check(g.observe(stranger, at: at(7)) == .lock, "restarted countdown locks")
}
do {
    var g = Guard(grace: .seconds(4), toleratedGap: .milliseconds(1500)); g.arm()
    _ = g.observe(stranger, at: at(0))
    check(g.observe(.unclear, at: at(1)) == .none, "short head-turn does not cancel")
    check(g.observe(.empty, at: at(1.4)) == .none, "short flicker does not cancel")
    _ = g.observe(stranger, at: at(2.5))
    check(g.observe(stranger, at: at(4)) == .lock, "flickering stranger still locked")
}
do {
    var g = Guard(grace: .seconds(4), toleratedGap: .milliseconds(1500)); g.arm()
    _ = g.observe(stranger, at: at(0))
    check(g.observe(.empty, at: at(2)) == .cancelWarning, "stranger leaving cancels warning")
}
do {
    var g = Guard(); g.arm(); _ = g.observe(stranger, at: at(0)); g.disarm()
    check(g.observe(stranger, at: at(10)) == .none, "disarm mid-warning prevents lock")
}

// MARK: Guard at the default 1 s grace (4 frames/s from the camera).

check(Guard().grace == .seconds(1), "default grace is 1 s")
do {
    var g = Guard(); g.arm()
    check(g.observe(stranger, at: at(0)) == .startWarning, "1 s: warning starts")
    check(g.observe(stranger, at: at(0.25)) == .none, "1 s: frame 2")
    check(g.observe(stranger, at: at(0.5)) == .none, "1 s: frame 3, not yet 1 s")
    check(g.observe(stranger, at: at(0.75)) == .none, "1 s: frame 4, not yet 1 s")
    check(g.observe(stranger, at: at(1.0)) == .lock, "1 s: locks one second after first sighting")
}
do {
    // Two stray misreads bracketing a gap must not lock, even though 1 s has passed.
    var g = Guard(); g.arm()
    _ = g.observe(stranger, at: at(0))
    _ = g.observe(.unclear, at: at(0.4))
    _ = g.observe(.unclear, at: at(0.7))
    check(g.observe(stranger, at: at(1.0)) == .none, "1 s: only 2 stranger frames, no lock")
    check(g.observe(stranger, at: at(1.25)) == .lock, "1 s: third stranger frame locks")
}
do {
    var g = Guard(); g.arm()
    _ = g.observe(stranger, at: at(0))
    _ = g.observe(stranger, at: at(0.25))
    check(g.observe(.owner, at: at(0.5)) == .cancelWarning, "1 s: owner still cancels")
}
do {
    // With 1 s grace the gap tolerance is capped at 1 s, so empty frames can't carry a warning further.
    var g = Guard(); g.arm()
    _ = g.observe(stranger, at: at(0))
    check(g.observe(.empty, at: at(1.2)) == .cancelWarning, "1 s: stranger gone >1 s cancels")
}

// MARK: Guard — key press or click while nobody is in view.

/// Armed at t=0, owner seen from 0 to 1 s, then gone.
func ownerLeftAt1s() -> Guard {
    var g = Guard(inputLock: true); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(0.5))
    _ = g.observe(.owner, at: at(1))
    _ = g.observe(.empty, at: at(1.5))
    return g
}
do {
    var g = Guard(inputLock: false); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(1))
    check(g.observe(.empty, at: at(20), lastInput: at(19.9)) == .none, "input: off means input never locks")
}
do {
    var g = ownerLeftAt1s()
    check(g.observe(.empty, at: at(20), lastInput: at(19.9)) == .startWarning, "input: key press in an empty room warns")
    check(g.warningReason == .unseenInput, "input: warning says why")
    check(g.observe(.empty, at: at(20.5)) == .none, "input: no lock before grace")
    check(g.observe(.empty, at: at(21), lastInput: at(19.9)) == .lock, "input: locks after 1 s")
    check(g.state == .locked, "input: lock disarms")
}
do {
    // Owner typing, then walking away: the last keystrokes are within 5 s of being seen.
    var g = ownerLeftAt1s()
    for s in stride(from: 1.5, through: 60, by: 0.25) {
        check(g.observe(.empty, at: at(s), lastInput: at(4.9)) == .none, "input: owner's typing while leaving never locks (t=\(s))")
    }
}
do {
    var g = ownerLeftAt1s()
    check(g.observe(.empty, at: at(6.5), lastInput: at(6.0)) == .startWarning, "input: first key 5 s after owner left warns")
}
do {
    // Owner glancing down at the keyboard: face gone for a moment while typing.
    var g = Guard(inputLock: true); g.arm(at: at(0))
    for s in stride(from: 0.25, through: 30, by: 0.25) {
        let obs: Observation = Int(s * 4) % 12 < 8 ? .owner : .empty   // 2 s of face, 1 s looking down
        check(g.observe(obs, at: at(s), lastInput: at(s - 0.1)) != .startWarning,
              "input: owner looking down while typing never warns (t=\(s))")
    }
}
do {
    // Input from before arming (e.g. the click on Turn On) never counts.
    var g = Guard(inputLock: true); g.arm(at: at(10))
    _ = g.observe(.owner, at: at(1))
    check(g.observe(.empty, at: at(20), lastInput: at(9)) == .none, "input: keys before arming ignored")
}
do {
    // Never saw the owner this session (armed while away): Mog can't tell whose hands those are.
    var g = Guard(inputLock: true); g.arm(at: at(0))
    check(g.observe(.empty, at: at(10), lastInput: at(9)) == .none, "input: needs to have seen the owner first")
}
do {
    var g = ownerLeftAt1s()
    check(g.observe(.unclear, at: at(20), lastInput: at(19.9)) == .none, "input: unclear face is not 'nobody'")
    check(g.observe(stranger, at: at(20.25), lastInput: at(19.9)) == .startWarning, "input: stranger still handled by face rule")
    check(g.warningReason == .stranger, "input: stranger reason wins when a face is visible")
}
do {
    var g = ownerLeftAt1s()
    _ = g.observe(.empty, at: at(20), lastInput: at(19.9))
    check(g.observe(.owner, at: at(20.5), lastInput: at(19.9)) == .cancelWarning, "input: owner coming back cancels")
    check(g.observe(.empty, at: at(21), lastInput: at(19.9)) == .none, "input: same key press can't warn twice")
    check(g.observe(.empty, at: at(23), lastInput: at(22.5)) == .none, "input: owner seen 2 s ago, fresh typing is theirs")
    check(g.observe(.empty, at: at(40), lastInput: at(39)) == .startWarning, "input: later key press warns again")
}
do {
    // Warning from input keeps running even if the room stays empty (the input was the evidence).
    var g = ownerLeftAt1s()
    _ = g.observe(.empty, at: at(20), lastInput: at(19.9))
    check(g.observe(.unclear, at: at(20.5)) == .none, "input: unclear frame doesn't cancel input warning")
    check(g.observe(.empty, at: at(21)) == .lock, "input: empty room still locks")
}
do {
    var g = ownerLeftAt1s()
    _ = g.observe(.empty, at: at(20), lastInput: at(19.9))
    g.disarm()
    check(g.observe(.empty, at: at(30), lastInput: at(29.9)) == .none, "input: disarm stops it")
}

// MARK: Guard — owner gate for Turn Off / Quit.

do {
    var g = Guard(); g.arm(at: at(0))
    check(!g.ownerSeen(within: .seconds(2), at: at(1)), "gate: owner never seen → refuse")
    _ = g.observe(.owner, at: at(10))
    check(g.ownerSeen(within: .seconds(2), at: at(11)), "gate: owner seen 1 s ago → allow")
    check(g.ownerSeen(within: .seconds(2), at: at(12)), "gate: exactly at window edge → allow")
    check(!g.ownerSeen(within: .seconds(2), at: at(12.5)), "gate: owner gone 2.5 s → refuse")
    _ = g.observe(strangerWithOwner, at: at(20))
    check(g.ownerSeen(within: .seconds(2), at: at(20.5)), "gate: owner with someone behind → allow")
    _ = g.observe(stranger, at: at(30))
    check(!g.ownerSeen(within: .seconds(2), at: at(30.5)), "gate: stranger alone → refuse")
}
do {
    var g = Guard(); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(1))
    g.disarm()
    check(!g.ownerSeen(within: .seconds(2), at: at(1.5)), "gate: not armed → nothing to gate")
}

// MARK: Classifier — turning faces into an observation.

let th = MatchThresholds(owner: 0.40, stranger: 0.33)
check(Classifier.observe([], thresholds: th) == .empty, "no faces is empty")
check(Classifier.observe([FaceVerdict(usable: false, similarity: nil)], thresholds: th) == .unclear,
      "unusable face is unclear, not stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.7)], thresholds: th) == .owner, "match is owner")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.1)], thresholds: th) == stranger, "mismatch is stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.4)], thresholds: th) == .owner, "owner threshold inclusive")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.37)], thresholds: th) == .unclear,
      "owner at awkward angle (0.37) is unsure, never a stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.33)], thresholds: th) == .unclear,
      "stranger threshold is exclusive")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.32)], thresholds: th) == stranger,
      "highest live stranger score (0.32) is still a stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.7), FaceVerdict(usable: true, similarity: 0.1)],
                         thresholds: th) == strangerWithOwner, "owner plus stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.1), FaceVerdict(usable: false, similarity: nil)],
                         thresholds: th) == stranger, "stranger plus unclear is stranger")
check(Classifier.observe([FaceVerdict(usable: true, similarity: 0.1), FaceVerdict(usable: true, similarity: 0.36)],
                         thresholds: th) == stranger, "stranger plus unsure is stranger")
check(MatchThresholds(owner: 0.4, stranger: 0.6).stranger == 0.4, "stranger cut-off clamped to owner cut-off")

// Replay the live test log (owner + 2 friends, 2026-09-29): every score must land correctly.
let liveOwner: [Float] = [0.95, 0.84, 0.75, 0.72, 0.69, 0.65, 0.61, 0.60, 0.47, 0.43, 0.40]
let liveOwnerAwkward: [Float] = [0.39, 0.38, 0.37]  // labelled STRANGER by the old single 0.40 cut-off
let liveStrangers: [Float] = [0.32, 0.30, 0.29, 0.24, 0.22, 0.14, 0.09, 0.02, -0.02, -0.03]
check(liveOwner.allSatisfy { th.label($0) == .owner }, "live owner scores are owner")
check(liveOwnerAwkward.allSatisfy { th.label($0) == .unsure }, "live awkward-angle owner scores no longer start a countdown")
check(liveStrangers.allSatisfy { th.label($0) == .stranger }, "live stranger scores are stranger")

// MARK: Embedding math.

let a = Embedding.l2Normalized([3, 4])
check(near(a[0], 0.6) && near(a[1], 0.8), "l2 normalize")
check(near(Embedding.similarity(a, a), 1), "self similarity is 1")
check(near(Embedding.similarity(Embedding.l2Normalized([1, 0]), Embedding.l2Normalized([0, 1])), 0), "orthogonal is 0")
check(Embedding.similarity([1, 0], [1]) == -1, "shape mismatch is -1")
check(near(Embedding.bestMatch(Embedding.l2Normalized([1, 1]), in: [[1, 0], Embedding.l2Normalized([1, 1])]), 1),
      "best match picks closest sample")

// MARK: Alignment.

do {
    let truth = Similarity(ar: 1.6 * cos(0.4), ai: 1.6 * sin(0.4), tx: -30, ty: 12)
    let src = [Point(100, 120), Point(160, 118), Point(108, 190), Point(150, 192)]
    let fit = Similarity.fit(from: src, to: src.map(truth.apply))!
    check(near(fit.ar, truth.ar) && near(fit.ai, truth.ai) && near(fit.tx, truth.tx, 0.01) && near(fit.ty, truth.ty, 0.01),
          "similarity fit recovers rotation, scale, translation")
    let p = Point(37, 88), back = fit.invert(fit.apply(p))
    check(near(back.x, p.x, 1e-2) && near(back.y, p.y, 1e-2), "invert undoes apply")
    check(Similarity.fit(from: [Point(1, 1), Point(1, 1)], to: [Point(0, 0), Point(5, 5)]) == nil, "degenerate fit rejected")
}
do {
    // Source: B = x, G = y. Translate by (-10, -20): template(u, v) samples image(u+10, v+20).
    let w = 200, h = 200, rb = w * 4
    var src = [UInt8](repeating: 0, count: rb * h)
    for y in 0..<h { for x in 0..<w { src[y * rb + x * 4] = UInt8(x); src[y * rb + x * 4 + 1] = UInt8(y) } }
    var dst = [UInt8](repeating: 0, count: 112 * 112 * 4)
    let shift = Similarity(ar: 1, ai: 0, tx: -10, ty: -20)
    src.withUnsafeBytes { s in dst.withUnsafeMutableBytes { d in
        Warp.alignedBGRA(src: s.baseAddress!, width: w, height: h, rowBytes: rb, transform: shift,
                         dst: d.baseAddress!, dstRowBytes: 112 * 4, size: 112)
    } }
    let px = (5 * 112 + 7) * 4
    check(dst[px] == 17 && dst[px + 1] == 25 && dst[px + 3] == 255, "warp samples through inverse transform")
}

// MARK: Profile storage.

do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mog-check-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let samples = (0..<Profile.minSamples).map { i in Embedding.l2Normalized([Float(i) + 1, 1, 2]) }
    let p = Profile(model: "m1", threshold: 0.4, samples: samples, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try! ProfileStore.save(p, to: url)
    let loaded = try! ProfileStore.load(from: url)!
    check(loaded == p, "profile round-trips")
    let perms = try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    check(perms == 0o600, "profile file is owner-only (0600)")
    check((try? loaded.validate(expectedModel: "m1")) != nil, "valid profile passes")
    check((try? loaded.validate(expectedModel: "other")) == nil, "profile from other model rejected")
    let few = Profile(model: "m1", threshold: 0.4, samples: Array(samples.prefix(2)))
    check((try? few.validate(expectedModel: "m1")) == nil, "too few samples rejected")
    check(p.thresholds == MatchThresholds(owner: 0.4, stranger: Profile.defaultStrangerBelow),
          "profile without stranger cut-off uses default")
    let old = #"{"version":1,"model":"m1","threshold":0.4,"samples":[[1]],"createdAt":"2026-09-29T00:00:00Z"}"#
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    check((try? decoder.decode(Profile.self, from: Data(old.utf8)))?.strangerBelow == nil,
          "profile saved before this change still loads")
    let bad = Profile(model: "m1", threshold: 0.4, strangerBelow: 0.5, samples: samples)
    check((try? bad.validate(expectedModel: "m1")) == nil, "stranger cut-off above owner cut-off rejected")
}

print("\nall \(passed) checks passed")
