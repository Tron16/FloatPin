import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Receives frames from ScreenCaptureKit on a background queue and hands
/// them to the main thread.
final class StreamReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((IOSurface) -> Void)?
    var onStop: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?() }
    }
}

/// The view inside the floating panel: shows the live frames, handles
/// dragging (so we can detect a shake to unpin) and double-click.
final class MirrorView: NSView {
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?

    var showBorder = true {
        didSet {
            layer?.borderWidth = showBorder ? 2 : 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        l.cornerRadius = 10
        l.masksToBounds = true
        l.borderColor = NSColor.controlAccentColor.cgColor
        l.borderWidth = 2
        layer = l          // layer-hosting: we own the layer's contents
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ surface: IOSurface) { layer?.contents = surface }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin, let window else { return }
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        onDrag?(p)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartOrigin = nil
    }
}

/// One pinned window: a floating panel showing a live copy of another app's window.
final class PinnedWindow: NSObject, NSWindowDelegate {
    let source: WinInfo
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let mirror = MirrorView(frame: .zero)
    private let receiver = StreamReceiver()
    private let queue = DispatchQueue(label: "floatpin.stream")
    private let shake = ShakeTracker()

    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var lastSize: CGSize
    private var lastFPS = Prefs.frameRate
    private var timer: Timer?
    private var activationObserver: Any?
    private var closing = false

    var title: String { source.displayName }

    init(source: WinInfo, index: Int) {
        self.source = source
        self.lastSize = source.bounds.size

        // Size: a fraction of the original, but never tiny.
        let scale = max(CGFloat(Prefs.pinScale), 200 / max(source.bounds.width, 1))
        let size = NSSize(width: source.bounds.width * scale, height: source.bounds.height * scale)

        // Place in the top-right corner of the screen the window is on, cascading.
        let cocoa = Geometry.toCocoa(source.bounds)
        let center = NSPoint(x: cocoa.midX, y: cocoa.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let offset = CGFloat(index % 6) * 32
        let origin = NSPoint(x: vf.maxX - size.width - 20 - offset,
                             y: vf.maxY - size.height - 20 - offset)

        panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = source.displayName
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .black
        panel.contentAspectRatio = source.bounds.size
        panel.contentMinSize = NSSize(width: 120, height: 80)
        panel.delegate = self
        panel.contentView = mirror

        mirror.onDoubleClick = { [weak self] in self?.focusOriginal() }
        mirror.onDragBegan = { [weak self] in self?.shake.reset() }
        mirror.onDrag = { [weak self] p in self?.handleDrag(p) }
        receiver.onFrame = { [weak self] surface in self?.mirror.show(surface) }
        receiver.onStop = { [weak self] in self?.unpin() }
    }

    // MARK: Lifecycle

    func start() {
        applyPrefs()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.panel.animator().alphaValue = CGFloat(Prefs.opacity)
        }
        startStream()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSource()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.appActivated(note)
        }
    }

    func unpin() { teardown(animated: true) }

    /// The panel's close button was clicked; it's already closing itself.
    func windowWillClose(_ notification: Notification) {
        teardown(animated: false, closePanel: false)
    }

    private func teardown(animated: Bool, closePanel: Bool = true) {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        timer = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        stream?.stopCapture { _ in }
        stream = nil
        onClose?()

        guard closePanel else { return }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.close()
            })
        } else {
            panel.close()
        }
    }

    /// Quick blink so you can tell this window is already pinned.
    func flash() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.panel.animator().alphaValue = 0.3
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.panel.animator().alphaValue = CGFloat(Prefs.opacity)
            }
        })
        panel.orderFrontRegardless()
    }

    // MARK: Settings

    func applyPrefs() {
        guard !closing else { return }
        if panel.isVisible { panel.alphaValue = CGFloat(Prefs.opacity) }
        panel.ignoresMouseEvents = Prefs.clickThrough
        mirror.showBorder = Prefs.showBorder
        if Prefs.frameRate != lastFPS {
            lastFPS = Prefs.frameRate
            stream?.updateConfiguration(makeConfig(size: lastSize)) { _ in }
        }
    }

    // MARK: Capture

    private func startStream() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !self.closing else { return }
                guard let scWindow = content?.windows.first(where: { $0.windowID == self.source.id }) else {
                    self.unpin()
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                self.filter = filter
                let stream = SCStream(filter: filter,
                                      configuration: self.makeConfig(size: scWindow.frame.size),
                                      delegate: self.receiver)
                do {
                    try stream.addStreamOutput(self.receiver, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.unpin()
                    return
                }
                self.stream = stream
                stream.startCapture { error in
                    if error != nil { DispatchQueue.main.async { self.unpin() } }
                }
            }
        }
    }

    private func makeConfig(size: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let scale = CGFloat(filter?.pointPixelScale ?? 2)
        c.width = max(2, Int(size.width * scale))
        c.height = max(2, Int(size.height * scale))
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Prefs.frameRate))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 5
        c.ignoreShadowsSingleWindow = true
        return c
    }

    /// Follows the original window: unpin if it closed, re-size if it changed size.
    private func checkSource() {
        guard !closing else { return }
        guard let b = WindowList.bounds(of: source.id) else { unpin(); return }
        guard abs(b.width - lastSize.width) > 1 || abs(b.height - lastSize.height) > 1,
              b.width > 0, b.height > 0 else { return }
        lastSize = b.size
        panel.contentAspectRatio = b.size
        let f = panel.frame
        let newHeight = f.width * b.height / b.width
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - newHeight, width: f.width, height: newHeight), display: true)
        stream?.updateConfiguration(makeConfig(size: b.size)) { _ in }
    }

    // MARK: Interaction

    private func handleDrag(_ p: NSPoint) {
        guard Prefs.shakeEnabled else { return }
        if shake.feed(p) {
            if Prefs.playSound { NSSound(named: "Bottle")?.play() }
            unpin()
        }
    }

    /// Double-click: jump to the real window.
    private func focusOriginal() {
        NSRunningApplication(processIdentifier: source.pid)?.activate()
        if let b = WindowList.bounds(of: source.id), Permissions.accessibility {
            AXHelper.raise(pid: source.pid, matching: b)
        }
    }

    /// Get out of the way while you're using the original app; come back when you leave it.
    private func appActivated(_ note: Notification) {
        guard !closing, Prefs.hideWhenSourceFront,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == source.pid {
            panel.orderOut(nil)
        } else {
            panel.alphaValue = CGFloat(Prefs.opacity)
            panel.orderFrontRegardless()
        }
    }
}

/// Keeps track of every pinned window.
final class PinManager {
    static let shared = PinManager()

    private(set) var pins: [PinnedWindow] = []
    var onChange: (() -> Void)?
    var onNeedsPermission: (() -> Void)?

    func pin(_ window: WinInfo) {
        guard Permissions.screenRecording else { onNeedsPermission?(); return }
        if let existing = pins.first(where: { $0.source.id == window.id }) {
            existing.flash()
            return
        }
        let p = PinnedWindow(source: window, index: pins.count)
        p.onClose = { [weak self, weak p] in
            guard let self, let p else { return }
            self.pins.removeAll { $0 === p }
            self.onChange?()
        }
        pins.append(p)
        p.start()
        if Prefs.playSound { NSSound(named: "Pop")?.play() }
        onChange?()
    }

    func unpinAll() { pins.forEach { $0.unpin() } }

    func applyPrefs() { pins.forEach { $0.applyPrefs() } }
}
