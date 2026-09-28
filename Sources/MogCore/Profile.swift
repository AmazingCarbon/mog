import Foundation

/// Enrolled owner: a set of normalized ArcFace embeddings plus the match threshold.
/// Stored as plain JSON with 0600 permissions. It contains no image, only 512 floats
/// per sample, which cannot be turned back into a photo.
public struct Profile: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let minSamples = 5
    /// Below this similarity a face counts as a stranger. Tuned on live data: two other
    /// people scored -0.03–0.32, the owner at awkward angles 0.34–0.47.
    public static let defaultStrangerBelow: Float = 0.33

    public var version: Int
    public var model: String
    /// Similarity at or above this is the owner.
    public var threshold: Float
    /// Optional per-profile stranger cut-off; older profiles omit it and get the default.
    public var strangerBelow: Float?
    public var samples: [[Float]]
    public var createdAt: Date

    public init(model: String, threshold: Float, strangerBelow: Float? = nil, samples: [[Float]],
                createdAt: Date = Date()) {
        self.version = Self.formatVersion
        self.model = model
        self.threshold = threshold
        self.strangerBelow = strangerBelow
        self.samples = samples
        self.createdAt = createdAt
    }

    public var thresholds: MatchThresholds {
        MatchThresholds(owner: threshold, stranger: strangerBelow ?? Self.defaultStrangerBelow)
    }

    public enum ValidationError: Error, CustomStringConvertible {
        case wrongVersion(Int), wrongModel(String), tooFewSamples(Int), badShape, badThreshold

        public var description: String {
            switch self {
            case .wrongVersion(let v): "profile format v\(v) is not supported; re-enroll"
            case .wrongModel(let m): "profile was made with model '\(m)'; re-enroll"
            case .tooFewSamples(let n): "profile has \(n) samples, need \(Profile.minSamples)"
            case .badShape: "profile samples have inconsistent sizes"
            case .badThreshold: "profile threshold is out of range"
            }
        }
    }

    public func validate(expectedModel: String) throws {
        guard version == Self.formatVersion else { throw ValidationError.wrongVersion(version) }
        guard model == expectedModel else { throw ValidationError.wrongModel(model) }
        guard samples.count >= Self.minSamples else { throw ValidationError.tooFewSamples(samples.count) }
        guard let n = samples.first?.count, n > 0, samples.allSatisfy({ $0.count == n }) else {
            throw ValidationError.badShape
        }
        guard threshold > 0, threshold < 1 else { throw ValidationError.badThreshold }
        if let s = strangerBelow, !(s > -1 && s <= threshold) { throw ValidationError.badThreshold }
    }
}

public enum ProfileStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mog/profile.json")
    }

    public static func load(from url: URL = defaultURL) throws -> Profile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Profile.self, from: Data(contentsOf: url))
    }

    public static func save(_ profile: Profile, to url: URL = defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func delete(at url: URL = defaultURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
