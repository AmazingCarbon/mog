import Foundation

/// One face found in a frame, reduced to what the lock decision needs.
public struct FaceVerdict: Equatable, Sendable {
    /// Large, frontal and aligned well enough to identify.
    public var usable: Bool
    /// Best cosine similarity to the enrolled owner (nil when not usable or no profile).
    public var similarity: Float?

    public init(usable: Bool, similarity: Float?) {
        self.usable = usable
        self.similarity = similarity
    }
}

/// Two cut-offs with a gap between them:
///   similarity ≥ owner    → the owner
///   similarity < stranger → someone else
///   in between            → unsure (counts as "unclear", never as a stranger)
/// The gap absorbs the owner at awkward angles (seen at 0.34–0.39 in live tests),
/// so a head turn can't start a lock countdown.
public struct MatchThresholds: Equatable, Sendable {
    public enum Label: Equatable, Sendable { case owner, stranger, unsure }

    public let owner: Float
    public let stranger: Float

    public init(owner: Float, stranger: Float) {
        self.owner = owner
        self.stranger = min(stranger, owner)
    }

    public func label(_ similarity: Float) -> Label {
        if similarity >= owner { return .owner }
        if similarity < stranger { return .stranger }
        return .unsure
    }
}

public enum Classifier {
    /// Collapse all faces in a frame into one observation for the Guard.
    public static func observe(_ faces: [FaceVerdict], thresholds: MatchThresholds) -> Observation {
        if faces.isEmpty { return .empty }
        var owners = 0, strangers = 0
        for face in faces where face.usable {
            guard let s = face.similarity else { continue }
            switch thresholds.label(s) {
            case .owner: owners += 1
            case .stranger: strangers += 1
            case .unsure: break
            }
        }
        if strangers > 0 { return .stranger(ownerAlsoPresent: owners > 0) }
        if owners > 0 { return .owner }
        return .unclear
    }
}
