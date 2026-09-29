import CoreML
import CoreVideo
import Foundation

public enum MogInfo {
    public static let version = "0.3.0"
    public static let bundleID = "io.github.c4rb0nx1.mog"
}

extension FaceEmbedder {
    /// Runs the model once on a flat grey image. Proves Core ML can load and execute it.
    /// Returns the embedding length (512).
    public func selfTest() throws -> Int {
        let buffer = try makeInputBuffer()
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return try embed(buffer).count
    }

    /// Compiles a `.mlpackage` into a `.mlmodelc` directory at `destination` (replacing it).
    /// Used by the Homebrew formula at install time.
    public static func compile(_ package: URL, to destination: URL) throws {
        final class Box: @unchecked Sendable { var result: Result<URL, Error>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await MLModel.compileModel(at: package)) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        let compiled = try box.result!.get()
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: compiled, to: destination)
    }
}

/// Assembles Mog.app from the MogBar binary. Shared by `mog install-app` and Scripts/build-app.sh.
public enum AppInstaller {
    public struct Result {
        public let app: URL
        public let modelPath: String
    }

    /// `AppIcon.icns`: in Homebrew's `share/mog/`, or `Assets/` in a source checkout.
    public static func locateIcon(near executable: URL) -> URL? {
        let fm = FileManager.default
        var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [dir.deletingLastPathComponent().appendingPathComponent("share/mog/AppIcon.icns")]
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("Assets/AppIcon.icns"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Assets/AppIcon.icns"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// - Parameters:
    ///   - bar: the built MogBar executable.
    ///   - model: the compiled face model.
    ///   - icon: `AppIcon.icns`, copied into the app if present.
    ///   - embedModel: copy the model (~125 MB) into the app instead of pointing at it.
    public static func install(bar: URL, model: URL, icon: URL? = nil, into directory: URL,
                               embedModel: Bool) throws -> Result {
        let fm = FileManager.default
        let app = directory.appendingPathComponent("Mog.app")
        let contents = app.appendingPathComponent("Contents")
        // Remove then recreate: a running copy keeps its already-mapped files, so this can't crash it.
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: bar, to: contents.appendingPathComponent("MacOS/Mog"))

        var plist: [String: Any] = [
            "CFBundleExecutable": "Mog",
            "CFBundleIdentifier": MogInfo.bundleID,
            "CFBundleName": "Mog",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": MogInfo.version,
            "CFBundleVersion": MogInfo.version,
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
            "NSCameraUsageDescription":
                "Mog checks, on this Mac only, whether the face in front of the screen is yours. Nothing is sent anywhere.",
        ]
        if let icon {
            try fm.copyItem(at: icon, to: contents.appendingPathComponent("Resources/AppIcon.icns"))
            plist["CFBundleIconFile"] = "AppIcon"
        }
        let modelPath: String
        if embedModel {
            let dst = contents.appendingPathComponent("Resources/FaceEmbedding.mlmodelc")
            try fm.copyItem(at: model, to: dst)
            modelPath = dst.path
        } else {
            modelPath = stablePath(for: model).path
            plist[FaceEmbedder.modelPathInfoKey] = modelPath
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        // Ad-hoc signature. macOS ties camera permission to it; reinstalling may ask again.
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return Result(app: app, modelPath: modelPath)
    }

    /// Homebrew keeps each version under `<prefix>/Cellar/mog/<version>/`, which changes on upgrade.
    /// `<prefix>/opt/mog/` always points at the current one, so the app keeps working after `brew upgrade`.
    public static func stablePath(for url: URL) -> URL {
        let parts = url.resolvingSymlinksInPath().pathComponents
        guard let i = parts.firstIndex(of: "Cellar"), i + 2 < parts.count, parts[i + 1] == "mog" else { return url }
        let stable = Array(parts[..<i]) + ["opt", "mog"] + Array(parts[(i + 3)...])
        return URL(fileURLWithPath: NSString.path(withComponents: stable))
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw EngineError.install("\(tool) failed: \(msg)")
        }
    }
}
