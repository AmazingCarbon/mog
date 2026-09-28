import Foundation

/// 2D point in image pixel coordinates, origin top-left, y down.
public struct Point: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
}

/// Least-squares similarity transform (rotation + uniform scale + translation, no reflection):
///   dst = a * src + t, with a = ar + i·ai treated as a complex number.
/// Used to warp a detected face onto ArcFace's canonical 112×112 layout.
public struct Similarity: Equatable, Sendable {
    public var ar: Float, ai: Float, tx: Float, ty: Float

    public init(ar: Float, ai: Float, tx: Float, ty: Float) {
        self.ar = ar; self.ai = ai; self.tx = tx; self.ty = ty
    }

    /// Closed-form fit. Returns nil for degenerate input (fewer than 2 points, or all identical).
    public static func fit(from src: [Point], to dst: [Point]) -> Similarity? {
        guard src.count >= 2, src.count == dst.count else { return nil }
        let n = Float(src.count)
        let spx = src.reduce(0) { $0 + $1.x } / n, spy = src.reduce(0) { $0 + $1.y } / n
        let dpx = dst.reduce(0) { $0 + $1.x } / n, dpy = dst.reduce(0) { $0 + $1.y } / n

        var num_r: Float = 0, num_i: Float = 0, den: Float = 0
        for (p, q) in zip(src, dst) {
            let px = p.x - spx, py = p.y - spy
            let qx = q.x - dpx, qy = q.y - dpy
            // conj(p) * q
            num_r += px * qx + py * qy
            num_i += px * qy - py * qx
            den += px * px + py * py
        }
        guard den > 1e-6 else { return nil }
        let ar = num_r / den, ai = num_i / den
        // t = mu_dst - a * mu_src
        let tx = dpx - (ar * spx - ai * spy)
        let ty = dpy - (ai * spx + ar * spy)
        return Similarity(ar: ar, ai: ai, tx: tx, ty: ty)
    }

    public var scale: Float { (ar * ar + ai * ai).squareRoot() }

    public func apply(_ p: Point) -> Point {
        Point(ar * p.x - ai * p.y + tx, ai * p.x + ar * p.y + ty)
    }

    /// Maps a destination point back to the source image (for sampling while warping).
    public func invert(_ q: Point) -> Point {
        let x = q.x - tx, y = q.y - ty
        let d = ar * ar + ai * ai
        // conj(a) / |a|^2 * (q - t)
        return Point((ar * x + ai * y) / d, (ar * y - ai * x) / d)
    }
}

public enum Warp {
    /// Fills a `size`×`size` BGRA destination by pulling each pixel back through
    /// `transform` (image → template) and bilinearly sampling the BGRA source.
    /// Out-of-bounds samples clamp to the nearest edge pixel.
    public static func alignedBGRA(
        src: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int,
        transform: Similarity,
        dst: UnsafeMutableRawPointer, dstRowBytes: Int, size: Int
    ) {
        let s = src.assumingMemoryBound(to: UInt8.self)
        let d = dst.assumingMemoryBound(to: UInt8.self)
        let maxX = width - 1, maxY = height - 1
        for v in 0..<size {
            for u in 0..<size {
                let p = transform.invert(Point(Float(u), Float(v)))
                let fx0 = p.x.rounded(.down), fy0 = p.y.rounded(.down)
                let fx = p.x - fx0, fy = p.y - fy0
                let x0 = min(max(Int(fx0), 0), maxX), x1 = min(max(Int(fx0) + 1, 0), maxX)
                let y0 = min(max(Int(fy0), 0), maxY), y1 = min(max(Int(fy0) + 1, 0), maxY)
                let o00 = y0 * rowBytes + x0 * 4, o10 = y0 * rowBytes + x1 * 4
                let o01 = y1 * rowBytes + x0 * 4, o11 = y1 * rowBytes + x1 * 4
                let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy, w11 = fx * fy
                let out = v * dstRowBytes + u * 4
                for c in 0..<3 {
                    let value = Float(s[o00 + c]) * w00 + Float(s[o10 + c]) * w10
                        + Float(s[o01 + c]) * w01 + Float(s[o11 + c]) * w11
                    d[out + c] = UInt8(min(max(value.rounded(), 0), 255))
                }
                d[out + 3] = 255
            }
        }
    }
}

/// InsightFace/ArcFace canonical landmark positions for a 112×112 aligned crop.
/// Order: eye with smaller x, eye with larger x, mouth corner smaller x, mouth corner larger x.
public enum ArcFaceTemplate {
    public static let size = 112
    public static let eyeLeft = Point(38.2946, 51.6963)
    public static let eyeRight = Point(73.5318, 51.5014)
    public static let mouthLeft = Point(41.5493, 92.3655)
    public static let mouthRight = Point(70.7299, 92.2041)
    public static var points: [Point] { [eyeLeft, eyeRight, mouthLeft, mouthRight] }
}
