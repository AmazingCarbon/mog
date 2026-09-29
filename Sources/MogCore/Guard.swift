import Foundation

/// What the camera saw in one analyzed frame.
public enum Observation: Equatable, Sendable {
    /// Nobody in view.
    case empty
    /// Only the owner is in view.
    case owner
    /// At least one face that is not the owner. `ownerAlsoPresent` = the owner is in frame too.
    case stranger(ownerAlsoPresent: Bool)
    /// A face is in view but too small/blurry/turned to identify.
    case unclear
}

public enum GuardState: Equatable, Sendable {
    case off
    /// Watching. Owner at the Mac (or recently seen), no threat.
    case watching
    /// Stranger in view without the owner. Counting down to lock.
    case warning(since: ContinuousClock.Instant)
    /// Lock was requested. Guard is disarmed; stays off until re-armed (no lock loops).
    case locked
}

public enum GuardAction: Equatable, Sendable {
    case none
    case startWarning
    case cancelWarning
    case lock
}

/// Why a countdown is running.
public enum WarningReason: Equatable, Sendable {
    /// A face that isn't the owner is in view without the owner.
    case stranger
    /// Nobody is in view, yet a key was pressed or a mouse button clicked.
    case unseenInput
}

/// The lock decision, isolated from camera and UI so it can be tested exhaustively.
///
/// Rules:
/// - Empty room never locks. Leaving the Mac is not a threat by itself.
/// - Owner in frame always cancels, even if a stranger is looking over the shoulder
///   (the owner is present and responsible).
/// - Stranger without owner must persist for `grace`, continuously, before lock.
///   Brief flickers (`toleratedGap`) of empty/unclear do not reset the countdown,
///   so a stranger cannot defeat it by turning their head for one frame.
/// - It also takes at least `minStrangerFrames` stranger frames. With a short grace (1 s ≈ 4
///   frames) that stops a couple of stray misreads, plus the gap tolerance, from locking.
/// - Unseen input (`inputLock`): a key press, click, pointer movement, scroll or trackpad gesture
///   while nobody is in view locks at once, no countdown. It counts only if it came after arming and
///   after the last frame that showed any face, so typing while you're in view never counts, even if
///   the next frame misses you. Only an empty frame counts; an unclear face is someone, not nobody.
///   Input made behind the lock screen (the password) never counts (`ignoreInput(upTo:)`).
/// - After `lock`, the guard disarms itself. The caller must re-arm explicitly.
public struct Guard: Sendable {
    public static let defaultGrace: Duration = .seconds(1)
    /// The input clock is re-derived from "seconds since last event" on every frame, so one event can
    /// appear to move by microseconds between frames. Anything this close is the same event.
    public static let inputJitter: Duration = .milliseconds(50)

    public let grace: Duration
    public let toleratedGap: Duration
    public let minStrangerFrames: Int
    public let inputLock: Bool

    public private(set) var state: GuardState = .off
    public private(set) var warningReason: WarningReason?
    private var lastStrangerAt: ContinuousClock.Instant?
    private var strangerFrames = 0
    private var armedAt: ContinuousClock.Instant?
    /// Last time the owner was in frame, in this session (kept across re-arming, cleared by disarm).
    private var lastOwnerAt: ContinuousClock.Instant?
    /// Last frame that showed any face at all (owner, stranger or unclear).
    private var lastFaceAt: ContinuousClock.Instant?
    /// Input at or before this instant has been accounted for and can't lock.
    private var lastHandledInput: ContinuousClock.Instant?

    public init(grace: Duration = Guard.defaultGrace, toleratedGap: Duration = .milliseconds(1500),
                minStrangerFrames: Int = 3, inputLock: Bool = false) {
        self.grace = grace
        // A gap longer than the countdown itself would let empty frames carry a warning to lock.
        self.toleratedGap = min(toleratedGap, max(grace, .milliseconds(500)))
        self.minStrangerFrames = max(1, minStrangerFrames)
        self.inputLock = inputLock
    }

    public var isArmed: Bool {
        switch state {
        case .watching, .warning: true
        case .off, .locked: false
        }
    }

    /// Starts watching. Input from before `now` never counts as unseen input.
    public mutating func arm(at now: ContinuousClock.Instant = .now) {
        state = .watching
        warningReason = nil
        lastStrangerAt = nil
        strangerFrames = 0
        armedAt = now
    }

    public mutating func disarm() {
        state = .off
        warningReason = nil
        lastStrangerAt = nil
        strangerFrames = 0
        armedAt = nil
        lastOwnerAt = nil
        lastFaceAt = nil
        lastHandledInput = nil
    }

    /// Input up to `now` never locks: call while the lock screen is up, so the password typed there
    /// doesn't count once the Mac is unlocked.
    public mutating func ignoreInput(upTo now: ContinuousClock.Instant) {
        lastHandledInput = max(lastHandledInput ?? now, now)
    }

    /// Seconds left before lock, while warning.
    public func remaining(at now: ContinuousClock.Instant) -> Duration? {
        guard case .warning(let since) = state else { return nil }
        return max(.zero, grace - (now - since))
    }

    /// - Parameter lastInput: when the last key press, click, pointer movement or scroll happened, if known.
    public mutating func observe(_ obs: Observation, at now: ContinuousClock.Instant,
                                 lastInput: ContinuousClock.Instant? = nil) -> GuardAction {
        let ownerInFrame = obs == .owner || obs == .stranger(ownerAlsoPresent: true)
        if ownerInFrame { lastOwnerAt = now }
        if obs != .empty { lastFaceAt = now }

        switch state {
        case .off, .locked:
            return .none

        case .watching:
            if case .stranger(ownerAlsoPresent: false) = obs {
                state = .warning(since: now)
                warningReason = .stranger
                lastStrangerAt = now
                strangerFrames = 1
                return .startWarning
            }
            if let input = unseenInput(obs, lastInput: lastInput) { return lockForInput(input) }
            return .none

        case .warning(let since):
            switch obs {
            case .owner, .stranger(ownerAlsoPresent: true):
                return cancel()

            case .stranger(ownerAlsoPresent: false):
                lastStrangerAt = now
                strangerFrames += 1
                if now - since >= grace && strangerFrames >= minStrangerFrames {
                    return lock()
                }
                return .none

            case .empty, .unclear:
                // The stranger ducked out of view and touched the Mac: that's unseen input.
                if let input = unseenInput(obs, lastInput: lastInput) { return lockForInput(input) }
                // Tolerate short gaps; a real departure cancels the warning.
                if let last = lastStrangerAt, now - last <= toleratedGap {
                    return .none
                }
                return cancel()
            }
        }
    }

    /// True if the owner was in frame within `window` before `now` (only while armed).
    public func ownerSeen(within window: Duration, at now: ContinuousClock.Instant) -> Bool {
        guard isArmed, let ownerAt = lastOwnerAt else { return false }
        return now - ownerAt <= window
    }

    /// The pending input, if it counts as someone using the Mac while nobody is in view.
    private func unseenInput(_ obs: Observation, lastInput: ContinuousClock.Instant?) -> ContinuousClock.Instant? {
        guard inputLock, obs == .empty, let input = lastInput, let armedAt,
              input > armedAt + Self.inputJitter else { return nil }
        // Made while a face was in view (the frame that showed it came after the input).
        if let face = lastFaceAt, input <= face { return nil }
        if let handled = lastHandledInput, input <= handled + Self.inputJitter { return nil }
        return input
    }

    private mutating func lockForInput(_ input: ContinuousClock.Instant) -> GuardAction {
        lastHandledInput = input
        warningReason = .unseenInput
        return lock()
    }

    private mutating func cancel() -> GuardAction {
        state = .watching
        warningReason = nil
        lastStrangerAt = nil
        strangerFrames = 0
        return .cancelWarning
    }

    private mutating func lock() -> GuardAction {
        state = .locked
        lastStrangerAt = nil
        strangerFrames = 0
        return .lock
    }
}
