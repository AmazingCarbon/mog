import CoreGraphics
import CoreVideo
import Foundation
import MogCore
import Vision

/// One detected face, measured and (if good enough) embedded.
public struct AnalyzedFace {
    /// Face box in pixel coordinates, origin top-left.
    public let box: CGRect
    public let yawDegrees: Double?
    /// Distance between eye centers, pixels. Proxy for how much detail the face has.
    public let eyeDistance: Double
    /// Why the face can't be identified; nil if usable.
    public let rejectReason: String?
    /// L2-normalized ArcFace embedding (nil if rejected).
    public let embedding: [Float]?

    public var usable: Bool { embedding != nil }
}

/// Finds faces, aligns each to ArcFace's 112×112 template using Vision landmarks, embeds it.
/// Not thread-safe; call from one queue.
public final class FaceAnalyzer {
    public var minEyeDistance: Double = 26
    public var maxYawDegrees: Double = 35
    public var maxFaces = 4
    /// Diagnostics: receives each aligned 112×112 crop before embedding.
    public var onAligned: ((CVPixelBuffer) -> Void)?

    private let embedder: FaceEmbedder

    public init(embedder: FaceEmbedder) {
        self.embedder = embedder
    }

    public func analyze(_ frame: CVPixelBuffer) -> [AnalyzedFace] {
        let request = VNDetectFaceLandmarksRequest()
        // Mac cameras deliver upright, unmirrored landscape frames.
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let observations = request.results, !observations.isEmpty else { return [] }

        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let size = CGSize(width: width, height: height)

        let largest = observations
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            .prefix(maxFaces)

        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }

        return largest.map { measure($0, frame: frame, size: size) }
    }

    private func measure(_ obs: VNFaceObservation, frame: CVPixelBuffer, size: CGSize) -> AnalyzedFace {
        let bb = obs.boundingBox
        let box = CGRect(x: bb.minX * size.width, y: (1 - bb.maxY) * size.height,
                         width: bb.width * size.width, height: bb.height * size.height)
        let yaw = obs.yaw.map { $0.doubleValue * 180 / .pi }

        func reject(_ reason: String, eyes: Double = 0) -> AnalyzedFace {
            AnalyzedFace(box: box, yawDegrees: yaw, eyeDistance: eyes, rejectReason: reason, embedding: nil)
        }

        guard let lm = obs.landmarks,
              let leftEye = lm.leftEye?.pointsInImage(imageSize: size), !leftEye.isEmpty,
              let rightEye = lm.rightEye?.pointsInImage(imageSize: size), !rightEye.isEmpty,
              let lips = lm.outerLips?.pointsInImage(imageSize: size), lips.count >= 2
        else { return reject("no landmarks") }

        // Vision points: origin bottom-left. Flip to top-left to match the pixel buffer rows.
        func flip(_ p: CGPoint) -> Point { Point(Float(p.x), Float(size.height - p.y)) }
        func center(_ pts: [CGPoint]) -> Point {
            let n = CGFloat(pts.count)
            return flip(CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n))
        }
        let eyes = [center(leftEye), center(rightEye)].sorted { $0.x < $1.x }
        let mouth = lips.map(flip).sorted { $0.x < $1.x }
        let eyeDistance = Double(hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y))

        if let yaw, abs(yaw) > maxYawDegrees { return reject("turned away (yaw \(Int(yaw))°)", eyes: eyeDistance) }
        if eyeDistance < minEyeDistance { return reject("too far / too small", eyes: eyeDistance) }

        let src = [eyes[0], eyes[1], mouth.first!, mouth.last!]
        guard let transform = Similarity.fit(from: src, to: ArcFaceTemplate.points) else {
            return reject("alignment failed", eyes: eyeDistance)
        }

        do {
            let aligned = try embedder.makeInputBuffer()
            CVPixelBufferLockBaseAddress(aligned, [])
            Warp.alignedBGRA(
                src: CVPixelBufferGetBaseAddress(frame)!,
                width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame),
                rowBytes: CVPixelBufferGetBytesPerRow(frame),
                transform: transform,
                dst: CVPixelBufferGetBaseAddress(aligned)!,
                dstRowBytes: CVPixelBufferGetBytesPerRow(aligned),
                size: FaceEmbedder.inputSize)
            CVPixelBufferUnlockBaseAddress(aligned, [])
            onAligned?(aligned)
            let embedding = try embedder.embed(aligned)
            return AnalyzedFace(box: box, yawDegrees: yaw, eyeDistance: eyeDistance, rejectReason: nil, embedding: embedding)
        } catch {
            return reject("embedding failed: \(error)", eyes: eyeDistance)
        }
    }
}
