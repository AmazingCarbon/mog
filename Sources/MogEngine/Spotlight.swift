import CoreImage
import CoreVideo
import Foundation
import Vision

/// The intruder photo: the biggest face that isn't the owner stays sharp, everyone and everything else
/// is blurred. Uses Vision's per-person masks (macOS 14+); if the chosen face can't be matched to a
/// person, a soft oval around the face stays sharp instead.
public enum Spotlight {
    /// Chooses whose face to keep: the biggest non-owner face (the person closest to the screen).
    /// `isOwner[i]` says whether face `i` matched the owner. Nil if there are only owner faces.
    public static func pick(_ boxes: [CGRect], isOwner: [Bool]) -> Int? {
        boxes.indices
            .filter { !(isOwner.indices.contains($0) && isOwner[$0]) }
            .max { boxes[$0].width * boxes[$0].height < boxes[$1].width * boxes[$1].height }
    }

    /// JPEG of `frame` with only the person whose face is `face` (pixel coordinates, origin top-left)
    /// in focus. Call on the camera queue while `frame` is valid. Nil if the frame can't be encoded.
    public static func jpeg(from frame: CVPixelBuffer, keeping face: CGRect?) -> Data? {
        let image = CIImage(cvPixelBuffer: frame)
        let output = face.map { highlight(image, frame: frame, face: $0) } ?? image
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(
            of: output, colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }

    /// The same, but gives up after `timeout` and returns nil, so a slow cut-out never delays the lock.
    /// The caller then uses the plain frame.
    public static func jpeg(from frame: CVPixelBuffer, keeping face: CGRect?, timeout: TimeInterval) -> Data? {
        final class Box: @unchecked Sendable { var data: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        work.async {
            box.data = jpeg(from: frame, keeping: face)
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? box.data : nil
    }

    /// Loads Vision's person-segmentation model ahead of time. The first use takes ~2.4 s on an M-series
    /// Mac, later ones ~0.3 s; call when guarding starts with the intruder photo on.
    public static func prewarm() {
        work.async {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 256, 256, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb else { return }
            let request = VNGeneratePersonInstanceMaskRequest()
            try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]).perform([request])
            _ = context.createCGImage(CIImage(cvPixelBuffer: pb).applyingGaussianBlur(sigma: 4),
                                      from: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private static let work = DispatchQueue(label: "mog.spotlight", qos: .userInitiated)

    private static let context = CIContext()

    private static func highlight(_ image: CIImage, frame: CVPixelBuffer, face: CGRect) -> CIImage {
        let extent = image.extent
        // Core Image's origin is bottom-left; the face box is top-left.
        let faceCI = CGRect(x: face.minX, y: extent.height - face.maxY, width: face.width, height: face.height)
        let blurred = image.clampedToExtent()
            // Subtle: background still recognisable, the kept person clearly stands out.
            .applyingGaussianBlur(sigma: max(5, Double(extent.width) / 180))
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.03])
        let mask = personMask(frame: frame, face: faceCI, extent: extent) ?? ovalMask(around: faceCI, extent: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// Mask of the one person whose body covers the face, from Vision's person instance segmentation.
    private static func personMask(frame: CVPixelBuffer, face: CGRect, extent: CGRect) -> CIImage? {
        let request = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil, let result = request.results?.first else { return nil }

        // Which instance covers the face? Sample the low-res instance map over the face box.
        let map = result.instanceMask
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let sx = Double(w) / extent.width, sy = Double(h) / extent.height
        var votes: [Int: Int] = [:]
        // Face box in map coordinates (map rows run top to bottom, like the pixel buffer).
        let x0 = max(0, Int(face.minX * sx)), x1 = min(w - 1, Int(face.maxX * sx))
        let y0 = max(0, Int((extent.height - face.maxY) * sy)), y1 = min(h - 1, Int((extent.height - face.minY) * sy))
        guard x0 <= x1, y0 <= y1 else { return nil }
        for y in y0...y1 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in x0...x1 where row[x] != 0 { votes[Int(row[x]), default: 0] += 1 }
        }
        // Needs a clear majority of the face box, or the mask could be someone standing behind.
        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        guard let (instance, count) = votes.max(by: { $0.value < $1.value }), count * 4 >= area,
              result.allInstances.contains(instance),
              let scaled = try? result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance),
                                                                   from: handler)
        else { return nil }
        // Soft edge so the cut-out doesn't look pasted on.
        return CIImage(cvPixelBuffer: scaled).clampedToExtent()
            .applyingGaussianBlur(sigma: 3).cropped(to: extent)
    }

    /// Fallback: a soft oval a bit larger than the face, head and shoulders.
    private static func ovalMask(around face: CGRect, extent: CGRect) -> CIImage {
        let center = CIVector(x: face.midX, y: face.midY - face.height * 0.15)
        let radius = max(face.width, face.height) * 0.9
        return CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": radius * 0.75,
            "inputRadius1": radius * 1.25,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.black,
        ])!.outputImage!.cropped(to: extent)
    }
}
