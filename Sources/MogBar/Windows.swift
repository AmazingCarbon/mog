import AppKit
import AVFoundation
import MogCore
import MogEngine

/// Live camera preview with progress while enrolling.
@MainActor
final class EnrollWindow: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer
    private let title = NSTextField(labelWithString: "Look at the screen")
    private let detail = NSTextField(labelWithString: "Starting camera…")
    private let bar = NSProgressIndicator()
    private let button = NSButton(title: "Cancel", target: nil, action: nil)
    private var finished = false

    init(session: AVCaptureSession, target: Int) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()

        window.title = "Enroll Your Face"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let video = NSView()
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor.black.cgColor
        video.layer?.cornerRadius = 10
        video.layer?.masksToBounds = true
        preview.videoGravity = .resizeAspectFill
        // Mirror the preview only, like a selfie camera. Recognition uses the unmirrored frames.
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        video.layer?.addSublayer(preview)

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 2
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(target)
        button.target = self
        button.action = #selector(close)
        button.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [video, title, detail, bar, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            video.widthAnchor.constraint(equalToConstant: 480),
            video.heightAnchor.constraint(equalToConstant: 300),
            bar.widthAnchor.constraint(equalTo: video.widthAnchor),
            detail.widthAnchor.constraint(equalTo: video.widthAnchor),
        ])
        detail.alignment = .center
        stack.layoutSubtreeIfNeeded()
        preview.frame = video.bounds
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func show(_ event: EnrollEvent) {
        switch event {
        case .hint(let s):
            detail.stringValue = s
        case .sample(let n, let target, _):
            bar.doubleValue = Double(n)
            title.stringValue = "Captured \(n) of \(target)"
            detail.stringValue = "Keep looking at the screen and move your head slightly."
        case .finished(let profile, let worst):
            finished = true
            bar.doubleValue = bar.maxValue
            title.stringValue = "Face enrolled"
            detail.stringValue = String(format: "%d samples saved. Self-match %.2f. Turn Mog on from the menu bar.",
                                        profile.samples.count, worst)
            button.title = "Done"
        case .failed(let message):
            finished = true
            title.stringValue = "Enrollment failed"
            detail.stringValue = message
            button.title = "Close"
        }
    }

    @objc func close() { window.close() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// Floating red countdown shown on every Space before Mog locks.
@MainActor
final class WarningPanel {
    private let panel: NSPanel
    private let heading = NSTextField(labelWithString: "Someone else is looking")
    private let label = NSTextField(labelWithString: "")

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.95).cgColor
        box.layer?.cornerRadius = 14

        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        label.textColor = .white

        let stack = NSStackView(views: [heading, label])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        panel.contentView = box
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    func show(secondsLeft: Double, reason: WarningReason) {
        heading.stringValue = reason == .unseenInput ? "Someone is typing while you're away" : "Someone else is looking"
        label.stringValue = String(format: "Locking in %.0f s unless you come back", secondsLeft.rounded(.up))
        guard !panel.isVisible else { return }
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
        NSSound.beep()
    }

    func hide() { panel.orderOut(nil) }
}
