import AVFoundation
import CoreVideo
import Foundation

/// Front camera → BGRA frames at a fixed analysis rate. `onFrame` runs on a private serial queue;
/// frames that arrive while the previous one is still being analyzed are dropped.
public final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var interval: TimeInterval = 0.25
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mog.camera")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var configured = false
    private var lastFrame = Date.distantPast

    public override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Runs on the camera queue; safe to call from inside `onFrame` (which already runs there).
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    /// Blocks until the user answers the permission prompt (first run only).
    public static func ensureAccess() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { granted = $0; done.signal() }
            done.wait()
            if !granted { throw EngineError.cameraDenied }
        default:
            throw EngineError.cameraDenied
        }
    }

    /// For a live preview layer (menu-bar enrollment window).
    public var captureSession: AVCaptureSession { session }

    public func start() throws {
        try Self.ensureAccess()
        var failure: Error?
        onQueue {
            do {
                if !configured { try configure(); configured = true }
                if !session.isRunning { session.startRunning() }
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    public func stop() {
        onQueue { if session.isRunning { session.stopRunning() } }
    }

    /// Starts or stops the camera to match `wanted()`, evaluated on the camera queue. Concurrent calls
    /// are serialized there, and each one reads the latest state, so the last call always wins.
    /// Safe to call from inside `onFrame`.
    public func reconcile(_ wanted: () -> Bool) throws {
        try Self.ensureAccess()
        var failure: Error?
        onQueue {
            let on = wanted()
            do {
                if on && !configured { try configure(); configured = true }
                if on && !session.isRunning { lastFrame = .distantPast; session.startRunning() }
                if !on && session.isRunning { session.stopRunning() }
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    public var isRunning: Bool { session.isRunning }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        else { throw EngineError.cameraMissing }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 720p keeps faces large enough to identify from arm's length.
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw EngineError.cameraConfig(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw EngineError.cameraConfig("cannot add input") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw EngineError.cameraConfig("cannot add output") }
        session.addOutput(output)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= interval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        onFrame?(pixels)
    }
}
