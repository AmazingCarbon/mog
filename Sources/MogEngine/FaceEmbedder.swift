import CoreML
import CoreVideo
import Foundation

public enum EngineError: Error, CustomStringConvertible {
    case modelNotFound([String])
    case modelLoad(String)
    case bufferPool
    case badOutput(String)
    case cameraDenied
    case cameraMissing
    case cameraConfig(String)
    case lockUnavailable
    case install(String)

    public var description: String {
        switch self {
        case .modelNotFound(let tried):
            "face model not found. Reinstall (`brew reinstall mog`) or run ./Scripts/fetch-model.sh. Looked in:\n  "
                + tried.joined(separator: "\n  ")
        case .modelLoad(let m): "could not load face model: \(m)"
        case .bufferPool: "could not allocate image buffers"
        case .badOutput(let m): "face model returned unexpected output: \(m)"
        case .cameraDenied:
            "camera access denied. Allow your terminal (or Mog) in System Settings → Privacy & Security → Camera."
        case .cameraMissing: "no camera found"
        case .cameraConfig(let m): "camera setup failed: \(m)"
        case .lockUnavailable: "macOS lock service unavailable on this system"
        case .install(let m): m
        }
    }
}

/// ArcFace LResNet100E-IR (ONNX Model Zoo, Apache-2.0), converted to Core ML fp16.
/// Input `faceImage`: 112×112 BGRA, raw 0–255 (normalization is inside the graph).
/// Output `embedding`: [1, 512]; L2-normalized here before use.
public final class FaceEmbedder {
    /// Pinned to the verified download (SHA-256 prefix). Profiles made with another model are rejected.
    public static let modelID = "arcface-r100-fp16-3644ff11"
    public static let inputSize = 112
    private static let inputName = "faceImage"
    private static let outputName = "embedding"

    private let model: MLModel
    private let pool: CVPixelBufferPool
    public let modelURL: URL

    public init(url: URL? = nil) throws {
        let resolved = try url ?? Self.locate()
        modelURL = resolved
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            model = try MLModel(contentsOf: resolved, configuration: config)
        } catch {
            throw EngineError.modelLoad(error.localizedDescription)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.inputSize,
            kCVPixelBufferHeightKey as String: Self.inputSize,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        guard let p else { throw EngineError.bufferPool }
        pool = p
    }

    /// Info.plist key `mog install-app` writes so the app finds Homebrew's copy of the model.
    public static let modelPathInfoKey = "MogModelPath"

    /// Search order: $MOG_MODEL, the app's Info.plist pointer, the app bundle, Homebrew's libexec next to
    /// the executable, ./Models, Models above the executable (dev builds), ~/.config/mog.
    public static func locate() throws -> URL {
        let fm = FileManager.default
        let name = "FaceEmbedding.mlmodelc"
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MOG_MODEL"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let path = Bundle.main.object(forInfoDictionaryKey: modelPathInfoKey) as? String {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(name))
        }
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        candidates.append(dir.deletingLastPathComponent().appendingPathComponent("libexec/\(name)"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Models/\(name)"))
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("Models/\(name)"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/mog/\(name)"))

        for url in candidates where fm.fileExists(atPath: url.appendingPathComponent("model.mil").path)
            || fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path) {
            return url
        }
        throw EngineError.modelNotFound(candidates.map(\.path))
    }

    /// A fresh 112×112 BGRA buffer to warp an aligned face into.
    public func makeInputBuffer() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let out else { throw EngineError.bufferPool }
        return out
    }

    public func embed(_ aligned: CVPixelBuffer) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: [
            Self.inputName: MLFeatureValue(pixelBuffer: aligned),
        ])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw EngineError.badOutput("no '\(Self.outputName)'")
        }
        guard array.count == 512 else { throw EngineError.badOutput("\(array.count) values, expected 512") }
        var v = [Float](repeating: 0, count: array.count)
        for i in 0..<array.count { v[i] = array[i].floatValue }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { throw EngineError.badOutput("zero or non-finite embedding") }
        return v.map { $0 / norm }
    }
}
