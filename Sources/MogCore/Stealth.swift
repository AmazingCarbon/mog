import Foundation

/// Stealth mode: the camera stays off (no green light) until someone touches the Mac. Then it
/// switches on just long enough to see who it is:
/// - the owner → camera off again; the owner is trusted while they keep using the Mac;
/// - a stranger → lock at once, no countdown;
/// - nobody identifiable within `checkTimeout` → lock (someone is touching the Mac out of view).
///
/// Trust ends after `idleAfter` without input, so the next touch after a pause is checked again.
/// After `lock`, the guard disarms itself like `Guard`; the caller must re-arm explicitly.
public enum StealthState: Equatable, Sendable {
    case off
    /// Camera off. The next key press, click or pointer movement starts a check.
    case idle
    /// Camera on, waiting for a verdict.
    case checking(since: ContinuousClock.Instant)
    /// Owner verified at `since`. Camera off while they keep using the Mac.
    case trusted(since: ContinuousClock.Instant)
    case locked
}

public enum StealthLockReason: Equatable, Sendable {
    /// A face that isn't the owner, without the owner.
    case stranger
    /// The owner didn't show up within the check timeout (nobody in view, or a face too unclear to identify).
    case notVerified
}

public enum StealthAction: Equatable, Sendable {
    case none
    /// Turn the camera on: someone touched the Mac.
    case startCheck
    /// The owner is there: turn the camera off.
    case verified
    /// The owner stopped using the Mac for `idleAfter`: the next touch will be checked.
    case trustExpired
    case lock(StealthLockReason)
}

public struct StealthGuard: Sendable {
    /// Short on purpose: someone who reaches the Mac within this long of the owner's last touch
    /// inherits the owner's trust. 10 s let a quick takeover through; 3 s is about the fastest a
    /// person can step in. The cost: resuming after a 3 s pause flashes the camera for a check.
    public static let defaultIdleAfter: Duration = .seconds(3)
    public static let defaultRecheckAfter: Duration = .seconds(60)
    public static let defaultCheckTimeout: Duration = .milliseconds(2500)
    /// The input clock is derived from "seconds since last event" each poll, so the same event can
    /// appear to move by a few microseconds between polls. Anything within this window is the same event.
    public static let inputJitter: Duration = .milliseconds(50)

    public let idleAfter: Duration
    public let recheckAfter: Duration
    public let checkTimeout: Duration
    public let minStrangerFrames: Int

    public private(set) var state: StealthState = .off
    /// Input at or before this instant has already been accounted for.
    private var watermark: ContinuousClock.Instant?
    /// Consecutive stranger frames in the current check.
    private var strangerStreak = 0

    /// - Parameters:
    ///   - idleAfter: how long the owner can leave the Mac untouched before the next touch is checked.
    ///   - recheckAfter: even with nonstop use, the first touch this long after the last check is
    ///     checked again, so someone who takes over within `idleAfter` of the owner leaving gets caught.
    ///   - checkTimeout: how long a check may take to find the owner before it locks. A cold camera
    ///     needs about 1 s to show a recognizable face.
    ///   - minStrangerFrames: consecutive stranger frames before locking. Two, so one misread frame
    ///     from a camera that is still adjusting its exposure can't lock the owner out.
    public init(idleAfter: Duration = StealthGuard.defaultIdleAfter,
                recheckAfter: Duration = StealthGuard.defaultRecheckAfter,
                checkTimeout: Duration = StealthGuard.defaultCheckTimeout,
                minStrangerFrames: Int = 2) {
        self.idleAfter = idleAfter
        self.recheckAfter = max(recheckAfter, idleAfter)
        self.checkTimeout = checkTimeout
        self.minStrangerFrames = max(1, minStrangerFrames)
    }

    public var isArmed: Bool {
        switch state {
        case .idle, .checking, .trusted: true
        case .off, .locked: false
        }
    }

    public var isChecking: Bool {
        if case .checking = state { true } else { false }
    }

    public var isTrusted: Bool {
        if case .trusted = state { true } else { false }
    }

    /// True if the owner was verified by the camera within `window` before `now`.
    public func verified(within window: Duration, at now: ContinuousClock.Instant) -> Bool {
        guard case .trusted(let since) = state else { return false }
        return now - since <= window
    }

    /// Starts guarding with the camera off. Input from before `now` never counts.
    public mutating func arm(at now: ContinuousClock.Instant) {
        state = .idle
        watermark = now
        strangerStreak = 0
    }

    public mutating func disarm() {
        state = .off
        watermark = nil
        strangerStreak = 0
    }

    /// The screen locked (by Mog or by hand): camera off, and nothing typed before `now`, such as the
    /// password on the lock screen, counts afterwards. Stays armed.
    public mutating func pause(at now: ContinuousClock.Instant) {
        guard isArmed else { return }
        state = .idle
        watermark = max(watermark ?? now, now)
        strangerStreak = 0
    }

    /// Checks right away, without waiting for input (the owner gate, or `mog test`).
    public mutating func checkNow(at now: ContinuousClock.Instant) -> StealthAction {
        switch state {
        case .idle, .trusted: begin(now)
        case .off, .checking, .locked: .none
        }
    }

    /// Call often (every ~50 ms) with the time of the latest key press, click or pointer movement.
    public mutating func poll(lastInput: ContinuousClock.Instant?, at now: ContinuousClock.Instant) -> StealthAction {
        switch state {
        case .off, .locked:
            return .none

        case .idle:
            guard let input = lastInput, let seen = watermark, isNew(input, after: seen) else { return .none }
            watermark = input
            return begin(now)

        case .checking(let since):
            if let input = lastInput, let seen = watermark, isNew(input, after: seen) { watermark = input }
            return now - since >= checkTimeout ? lock(.notVerified) : .none

        case .trusted(let since):
            // Last moment the owner was known to be using the Mac.
            let active = max(watermark ?? since, since)
            if let input = lastInput, isNew(input, after: active) {
                watermark = input
                // A pause this poll didn't see (the Mac slept, the poll ran late): still a return.
                if input - active >= idleAfter || now - since >= recheckAfter { return begin(now) }
                return .none
            }
            guard now - active >= idleAfter else { return .none }
            watermark = active
            state = .idle
            return .trustExpired
        }
    }

    /// Call with each analyzed camera frame. Frames outside a check are ignored.
    public mutating func observe(_ obs: Observation, at now: ContinuousClock.Instant) -> StealthAction {
        guard case .checking(let since) = state else { return .none }
        switch obs {
        case .owner, .stranger(ownerAlsoPresent: true):
            // The owner is there (and responsible for anyone behind them).
            state = .trusted(since: now)
            strangerStreak = 0
            return .verified
        case .stranger(ownerAlsoPresent: false):
            strangerStreak += 1
            if strangerStreak >= minStrangerFrames { return lock(.stranger) }
        case .empty, .unclear:
            strangerStreak = 0
        }
        return now - since >= checkTimeout ? lock(.notVerified) : .none
    }

    private func isNew(_ input: ContinuousClock.Instant, after mark: ContinuousClock.Instant) -> Bool {
        input > mark + Self.inputJitter
    }

    private mutating func begin(_ now: ContinuousClock.Instant) -> StealthAction {
        state = .checking(since: now)
        strangerStreak = 0
        return .startCheck
    }

    private mutating func lock(_ reason: StealthLockReason) -> StealthAction {
        state = .locked
        strangerStreak = 0
        return .lock(reason)
    }
}
