import Foundation

/// Math for ArcFace embeddings. ArcFace vectors are compared by cosine similarity
/// after L2 normalization: same person is typically > 0.5, different people < 0.3.
public enum Embedding {
    public static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity of two already-normalized vectors. Returns -1 on shape mismatch.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return -1 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }

    /// Best similarity of `candidate` against any enrolled sample.
    public static func bestMatch(_ candidate: [Float], in samples: [[Float]]) -> Float {
        samples.map { similarity(candidate, $0) }.max() ?? -1
    }
}
