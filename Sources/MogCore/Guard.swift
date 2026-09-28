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
/// - After `lock`, the guard disarms itself. The caller must re-arm explicitly.
public struct Guard: Sendable {
    public static let defaultGrace: Duration = .seconds(1)

    public let grace: Duration
    public let toleratedGap: Duration
    public let minStrangerFrames: Int

    public private(set) var state: GuardState = .off
    private var lastStrangerAt: ContinuousClock.Instant?
    private var strangerFrames = 0

    public init(grace: Duration = Guard.defaultGrace, toleratedGap: Duration = .milliseconds(1500),
                minStrangerFrames: Int = 3) {
        self.grace = grace
        // A gap longer than the countdown itself would let empty frames carry a warning to lock.
        self.toleratedGap = min(toleratedGap, max(grace, .milliseconds(500)))
        self.minStrangerFrames = max(1, minStrangerFrames)
    }

    public var isArmed: Bool {
        switch state {
        case .watching, .warning: true
        case .off, .locked: false
        }
    }

    public mutating func arm() {
        state = .watching
        lastStrangerAt = nil
        strangerFrames = 0
    }

    public mutating func disarm() {
        state = .off
        lastStrangerAt = nil
        strangerFrames = 0
    }

    /// Seconds left before lock, while warning.
    public func remaining(at now: ContinuousClock.Instant) -> Duration? {
        guard case .warning(let since) = state else { return nil }
        return max(.zero, grace - (now - since))
    }

    public mutating func observe(_ obs: Observation, at now: ContinuousClock.Instant) -> GuardAction {
        switch state {
        case .off, .locked:
            return .none

        case .watching:
            if case .stranger(ownerAlsoPresent: false) = obs {
                state = .warning(since: now)
                lastStrangerAt = now
                strangerFrames = 1
                return .startWarning
            }
            return .none

        case .warning(let since):
            switch obs {
            case .owner, .stranger(ownerAlsoPresent: true):
                state = .watching
                lastStrangerAt = nil
                strangerFrames = 0
                return .cancelWarning

            case .stranger(ownerAlsoPresent: false):
                lastStrangerAt = now
                strangerFrames += 1
                if now - since >= grace && strangerFrames >= minStrangerFrames {
                    state = .locked
                    lastStrangerAt = nil
                    strangerFrames = 0
                    return .lock
                }
                return .none

            case .empty, .unclear:
                // Tolerate short gaps; a real departure cancels the warning.
                if let last = lastStrangerAt, now - last <= toleratedGap {
                    return .none
                }
                state = .watching
                lastStrangerAt = nil
                strangerFrames = 0
                return .cancelWarning
            }
        }
    }
}
