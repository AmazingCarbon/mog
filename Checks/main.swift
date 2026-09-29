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
    check(g.observe(.empty, at: at(20), lastInput: at(19.9)) == .lock, "input: touch in an empty room locks at once")
    check(g.warningReason == .unseenInput, "input: lock says why")
    check(g.state == .locked && !g.isArmed, "input: lock disarms")
    check(g.observe(.empty, at: at(30), lastInput: at(29.9)) == .none, "input: no lock loop")
}
do {
    // No 5 s wait any more: touching the Mac right after the owner's face leaves the frame locks.
    var g = ownerLeftAt1s()
    check(g.observe(.empty, at: at(1.75), lastInput: at(1.6)) == .lock, "input: touch 0.1 s after the face left locks")
}
do {
    // No need to have seen the owner first: armed while away, a touch with nobody in view locks.
    var g = Guard(inputLock: true); g.arm(at: at(0))
    check(g.observe(.empty, at: at(10), lastInput: at(9)) == .lock, "input: owner never seen, touch still locks")
}
do {
    // Typing while in view never counts, even when the next frame misses the face.
    var g = Guard(inputLock: true); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(1))
    check(g.observe(.empty, at: at(1.25), lastInput: at(0.95)) == .none, "input: key made while the face was in view ignored")
    check(g.observe(.empty, at: at(1.5), lastInput: at(0.95)) == .none, "input: still ignored on later empty frames")
}
do {
    // Owner looking down at the keyboard and typing: this now locks (option b, by request).
    var g = Guard(inputLock: true); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(1))
    check(g.observe(.empty, at: at(1.5), lastInput: at(1.4)) == .lock, "input: face gone + key press locks, even the owner's")
}
do {
    // Input from before arming (the click on Turn On) never counts.
    var g = Guard(inputLock: true); g.arm(at: at(10))
    check(g.observe(.empty, at: at(20), lastInput: at(9.99)) == .none, "input: touches before arming ignored")
    check(g.observe(.empty, at: at(20.25), lastInput: at(10.03)) == .none, "input: within jitter of arming ignored")
}
do {
    var g = ownerLeftAt1s()
    check(g.observe(.unclear, at: at(20), lastInput: at(19.9)) == .none, "input: unclear face is not 'nobody'")
    check(g.observe(.empty, at: at(20.25), lastInput: at(19.9)) == .none, "input: key made while a face was in view ignored")
    check(g.observe(.empty, at: at(21), lastInput: at(20.9)) == .lock, "input: next touch with nobody in view locks")
}
do {
    // A stranger ducks out of view mid-countdown and types: locks at once, not after the countdown.
    var g = ownerLeftAt1s()
    check(g.observe(stranger, at: at(20)) == .startWarning, "input: stranger warning starts")
    check(g.observe(.empty, at: at(20.25), lastInput: at(20.2)) == .lock, "input: stranger vanished + touch locks at once")
    check(g.warningReason == .unseenInput, "input: reason is the touch")
}
do {
    // The password typed on the lock screen doesn't count after unlocking.
    var g = ownerLeftAt1s()
    g.ignoreInput(upTo: at(30))
    check(g.observe(.empty, at: at(31), lastInput: at(29.5)) == .none, "input: lock-screen typing ignored after unlock")
    check(g.observe(.empty, at: at(40), lastInput: at(39.9)) == .lock, "input: later touch still locks")
}
do {
    // The same event, re-derived each frame, drifts by microseconds: never a new touch.
    var g = Guard(inputLock: true); g.arm(at: at(0))
    _ = g.observe(.owner, at: at(5))
    check(g.observe(.empty, at: at(5.25), lastInput: at(4.99)) == .none, "input jitter: key at 4.99 during face")
    check(g.observe(.empty, at: at(5.5), lastInput: at(4.991)) == .none, "input jitter: same key 1 ms later is not new")
}
do {
    var g = ownerLeftAt1s()
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

// MARK: Stealth — camera off until someone touches the Mac.

do {
    var g = StealthGuard()
    check(g.poll(lastInput: at(1), at: at(2)) == .none, "stealth: unarmed ignores input")
    check(!g.isArmed, "stealth: starts disarmed")
    g.arm(at: at(10))
    check(g.state == .idle && !g.isChecking, "stealth: arms with the camera off")
    check(g.poll(lastInput: at(9), at: at(10.05)) == .none, "stealth: input from before arming ignored")
    check(g.poll(lastInput: nil, at: at(11)) == .none, "stealth: no input, no check")
    for s in stride(from: 11.0, through: 600, by: 0.05) {
        if g.poll(lastInput: at(9), at: at(s)) != .none { check(false, "stealth: untouched Mac never wakes the camera") }
    }
    check(g.state == .idle, "stealth: 10 untouched minutes, camera still off")
}
do {
    // Owner comes back and types: one check, then the camera stays off while they work.
    var g = StealthGuard(); g.arm(at: at(0))
    check(g.poll(lastInput: at(5), at: at(5.05)) == .startCheck, "stealth: touch starts a check")
    check(g.isChecking, "stealth: camera on while checking")
    check(g.observe(.empty, at: at(5.5)) == .none, "stealth: dark first frames don't lock")
    check(g.observe(.unclear, at: at(5.8)) == .none, "stealth: unclear frames don't lock")
    check(g.observe(.owner, at: at(6.0)) == .verified, "stealth: owner verified")
    check(g.isTrusted && !g.isChecking, "stealth: camera off after verifying")
    for s in stride(from: 6.05, through: 60, by: 0.05) {
        if g.poll(lastInput: at(s - 0.02), at: at(s)) != .none { check(false, "stealth: owner typing stays trusted (t=\(s))") }
    }
    check(g.isTrusted, "stealth: a minute of typing, no re-check")
    check(g.observe(stranger, at: at(30)) == .none, "stealth: frames outside a check ignored")
}
do {
    // Owner leaves: trust expires, the next touch is checked again.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(1), at: at(1.05)); _ = g.observe(.owner, at: at(1.5))
    _ = g.poll(lastInput: at(3), at: at(3.05))
    check(g.poll(lastInput: at(3), at: at(12.9)) == .none, "stealth: trusted until 10 s untouched")
    check(g.poll(lastInput: at(3), at: at(13.05)) == .trustExpired, "stealth: 10 s untouched ends trust")
    check(g.state == .idle, "stealth: back to camera off")
    check(g.poll(lastInput: at(3), at: at(20)) == .none, "stealth: old input doesn't re-trigger")
    check(g.poll(lastInput: at(40), at: at(40.05)) == .startCheck, "stealth: next touch checked")
    check(g.observe(stranger, at: at(41.0)) == .none, "stealth: one stranger frame not enough")
    check(g.observe(stranger, at: at(41.03)) == .lock(.stranger), "stealth: second stranger frame locks at once")
    check(g.state == .locked && !g.isArmed, "stealth: lock disarms")
    check(g.poll(lastInput: at(50), at: at(50.05)) == .none, "stealth: no lock loop")
}
do {
    // A pause the poll didn't see (Mac asleep): the first touch after it still gets checked.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(1), at: at(1.05)); _ = g.observe(.owner, at: at(1.5))
    check(g.poll(lastInput: at(100), at: at(100.05)) == .startCheck, "stealth: touch after an unseen pause is checked")
}
do {
    // Stranger takes over within seconds of the owner leaving: caught by the periodic re-check.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(1), at: at(1.05)); _ = g.observe(.owner, at: at(1.5))
    var rechecked: Double?
    for s in stride(from: 1.6, through: 400, by: 0.05) where rechecked == nil {
        if g.poll(lastInput: at(s - 0.02), at: at(s)) == .startCheck { rechecked = s }
    }
    check(rechecked.map { $0 >= 301.5 && $0 < 302 } == true, "stealth: nonstop use re-checked after 5 min")
    check(g.observe(stranger, at: at(302)) == .none && g.observe(stranger, at: at(302.05)) == .lock(.stranger),
          "stealth: stranger who took over caught by re-check")
}
do {
    // Touching out of view: nobody identifiable within 2.5 s locks.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05))
    for s in stride(from: 5.1, to: 7.55, by: 0.05) {
        if g.observe(s < 6 ? .empty : .unclear, at: at(s)) != .none { check(false, "stealth: no lock before timeout (t=\(s))") }
    }
    check(g.observe(.empty, at: at(7.55)) == .lock(.notVerified), "stealth: nobody within 2.5 s locks")
}
do {
    // Camera never delivers a frame (broken, taken by another app): the poll enforces the timeout.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05))
    check(g.poll(lastInput: at(6), at: at(7.5)) == .none, "stealth: still waiting before timeout")
    check(g.poll(lastInput: at(6), at: at(7.6)) == .lock(.notVerified), "stealth: no frames at all still locks")
}
do {
    // Stranger misread interleaved with the owner: owner wins; single misreads reset the streak.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05))
    check(g.observe(stranger, at: at(5.5)) == .none, "stealth: misread 1")
    check(g.observe(.unclear, at: at(5.55)) == .none, "stealth: streak broken")
    check(g.observe(stranger, at: at(5.6)) == .none, "stealth: misread 2 alone doesn't lock")
    check(g.observe(.owner, at: at(5.65)) == .verified, "stealth: owner wins")
}
do {
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05))
    check(g.observe(strangerWithOwner, at: at(5.5)) == .verified, "stealth: owner with someone behind is verified")
}
do {
    // Owner gate: verified recently → allowed without a new check; otherwise a check runs.
    var g = StealthGuard(); g.arm(at: at(0))
    check(!g.verified(within: .seconds(2), at: at(1)), "stealth gate: not verified yet")
    check(g.checkNow(at: at(1)) == .startCheck, "stealth gate: check on demand")
    check(g.checkNow(at: at(1.1)) == .none, "stealth gate: no double check")
    _ = g.observe(.owner, at: at(1.5))
    check(g.verified(within: .seconds(2), at: at(3)), "stealth gate: verified 1.5 s ago → allow")
    check(!g.verified(within: .seconds(2), at: at(4)), "stealth gate: 2.5 s ago → check again")
    check(g.checkNow(at: at(4)) == .startCheck, "stealth gate: re-check from trusted")
    check(g.poll(lastInput: nil, at: at(6.5)) == .lock(.notVerified), "stealth gate: nobody → lock")
}
do {
    // Screen locked by hand: camera off; the password typed on the lock screen doesn't wake it.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05))
    g.pause(at: at(6))
    check(g.state == .idle && g.isArmed, "stealth: lock screen pauses, stays armed")
    check(g.poll(lastInput: at(5.9), at: at(20)) == .none, "stealth: typing before the pause ignored")
    check(g.poll(lastInput: at(21), at: at(21.05)) == .startCheck, "stealth: after unlock, touch is checked")
    g.disarm(); g.pause(at: at(30))
    check(g.state == .off, "stealth: pause doesn't arm a disarmed guard")
}
do {
    // The same input, re-derived each poll, can drift by microseconds: not a new touch.
    var g = StealthGuard(); g.arm(at: at(0))
    _ = g.poll(lastInput: at(5), at: at(5.05)); _ = g.observe(.owner, at: at(5.5))
    _ = g.poll(lastInput: at(5), at: at(15.6))
    check(g.state == .idle, "stealth jitter: trust expired")
    check(g.poll(lastInput: at(5.001), at: at(16)) == .none, "stealth jitter: 1 ms drift is not a touch")
}

// MARK: Update check — reading the formula and comparing versions.

do {
    let formula = """
    class Mog < Formula
      desc "Lock your Mac when someone else looks at it"
      url "https://github.com/c4rb0nx1/mog/archive/refs/tags/v0.3.0.tar.gz"
      sha256 "abc"
      resource "face-model" do
        url "https://huggingface.co/RuiSumida/ArcFace-R100-CoreML/resolve/b51b655/FaceEmbedding.mlpackage.tar.gz"
      end
    end
    """
    check(UpdateInfo.version(inFormula: formula) == "0.3.0", "update: version read from formula url")
    check(UpdateInfo.version(inFormula: "url \"https://x/refs/tags/v1.10.2.tar.gz\"") == "1.10.2", "update: multi-digit version")
    check(UpdateInfo.version(inFormula: "class Mog < Formula\nend") == nil, "update: no url, no version")
    check(UpdateInfo.version(inFormula: "url \"https://x/refs/tags/vbeta.tar.gz\"") == nil, "update: junk tag ignored")
    check(UpdateInfo.version(inFormula: "<html>404</html>") == nil, "update: error page is not a version")
    check(UpdateInfo.isNewer("0.3.0", than: "0.2.0"), "update: 0.3.0 > 0.2.0")
    check(UpdateInfo.isNewer("0.10.0", than: "0.9.0"), "update: numeric, not text, compare")
    check(UpdateInfo.isNewer("1.0", than: "0.99.9"), "update: major wins")
    check(!UpdateInfo.isNewer("0.3.0", than: "0.3.0"), "update: same version is not newer")
    check(!UpdateInfo.isNewer("0.3", than: "0.3.0"), "update: 0.3 == 0.3.0")
    check(!UpdateInfo.isNewer("0.2.0", than: "0.3.0"), "update: older is not newer (local build ahead of tap)")
    check(!UpdateInfo.isNewer("garbage", than: "0.3.0"), "update: unparsable is never newer")
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
