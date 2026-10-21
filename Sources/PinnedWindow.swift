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

/// The view that fills the floating panel. It draws the live frames and
/// handles everything a real window would: drag to move, drag the edges to
/// resize, and click to "become" the real window.
final class MirrorView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?

    /// Width:height of the source window, kept while resizing.
    var aspect = CGSize(width: 16, height: 10)

    private struct Edges {
        var left = false, right = false, top = false, bottom = false
        var any: Bool { left || right || top || bottom }
    }
    private enum Mode { case idle, move, resize(Edges) }

    private var mode = Mode.idle
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var moved = false
    private let grip: CGFloat = 8
    private var hadFirstFrame = false

    var showBorder = false {
        didSet { layer?.borderWidth = showBorder ? 2 : 0 }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.backgroundColor = NSColor.clear.cgColor   // the window's own rounded corners show through
        l.cornerRadius = 12
        l.borderColor = NSColor.controlAccentColor.cgColor
        l.borderWidth = 0
        layer = l          // layer-hosting: we own the layer's contents
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ surface: IOSurface) {
        layer?.contents = surface
        if !hadFirstFrame {
            hadFirstFrame = true
            window?.invalidateShadow()   // shadow follows the window's real shape
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Cursor feedback on the edges

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let e = edges(at: convert(event.locationInWindow, from: nil))
        if (e.left || e.right) && !(e.top || e.bottom) { NSCursor.resizeLeftRight.set() }
        else if (e.top || e.bottom) && !(e.left || e.right) { NSCursor.resizeUpDown.set() }
        else if e.any { NSCursor.crosshair.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    private func edges(at p: NSPoint) -> Edges {
        Edges(left: p.x < grip, right: p.x > bounds.width - grip,
              top: p.y > bounds.height - grip, bottom: p.y < grip)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        moved = false
        let e = edges(at: convert(event.locationInWindow, from: nil))
        mode = e.any ? .resize(e) : .move
        if case .move = mode { onDragBegan?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = p.y - startMouse.y
        if hypot(dx, dy) > 3 { moved = true }

        switch mode {
        case .idle:
            return
        case .move:
            window.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
            onDrag?(p)
        case .resize(let e):
            window.setFrame(resized(startFrame, edges: e, dx: dx, dy: dy), display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move = mode, !moved { onClick?() }
        mode = .idle
    }

    /// New frame for an edge/corner drag, keeping the aspect ratio and
    /// pinning the opposite edge in place.
    private func resized(_ f: NSRect, edges e: Edges, dx: CGFloat, dy: CGFloat) -> NSRect {
        let ratio = aspect.height > 0 ? aspect.width / aspect.height : 1.6
        var w = f.width
        var h = f.height
        if e.right { w = f.width + dx }
        if e.left { w = f.width - dx }
        if e.top { h = f.height + dy }
        if e.bottom { h = f.height - dy }

        let horizontal = e.left || e.right
        let vertical = e.top || e.bottom
        if horizontal && !vertical { h = w / ratio }
        else if vertical && !horizontal { w = h * ratio }
        else if abs(w - f.width) >= abs(h - f.height) * ratio { h = w / ratio }
        else { w = h * ratio }

        w = max(160, w)
        h = w / ratio

        var x = f.minX
        var y = f.minY
        if e.left { x = f.maxX - w }
        if e.bottom || !vertical { y = f.maxY - h }   // side drags keep the top edge fixed
        return NSRect(x: x, y: y, width: w, height: h)
    }
}

/// One pinned window: a floating panel showing a live copy of another app's
/// window, sitting exactly where the original is. Click it and the real
/// window moves to the pin's spot and size and comes forward.
final class PinnedWindow: NSObject {
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
    /// True while we're tucked away because you're using the real window.
    private var handedOff = false

    var title: String { source.displayName }

    init(source: WinInfo) {
        self.source = source
        self.lastSize = source.bounds.size

        // Same size, same spot as the original.
        panel = NSPanel(contentRect: Geometry.toCocoa(source.bounds),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = source.displayName
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false            // MirrorView moves it, so we can watch for shakes
        panel.acceptsMouseMovedEvents = true
        panel.contentView = mirror
        mirror.aspect = source.bounds.size

        mirror.onClick = { [weak self] in self?.handOffToRealWindow() }
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

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSource()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.appActivated(note)
        }
    }

    func unpin() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        timer = nil
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        stream?.stopCapture { _ in }
        stream = nil
        onClose?()

        if panel.isVisible {
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
        if handedOff { reappear() }
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

    /// Follows the original window: unpin if it closed, keep the stream's
    /// resolution and the pin's aspect ratio in step if it changed size.
    private func checkSource() {
        guard !closing else { return }
        guard let b = WindowList.bounds(of: source.id) else { unpin(); return }
        guard abs(b.width - lastSize.width) > 1 || abs(b.height - lastSize.height) > 1,
              b.width > 0, b.height > 0 else { return }
        lastSize = b.size
        mirror.aspect = b.size
        stream?.updateConfiguration(makeConfig(size: b.size)) { _ in }
        if !handedOff {
            // Keep the pin's width and top-left corner, fix the height to the new shape.
            let f = panel.frame
            let h = f.width * b.height / b.width
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
        }
    }

    // MARK: Handing off between the pin and the real window

    /// Click: move the real window to exactly where the pin is (same size),
    /// bring it forward, and step aside.
    private func handOffToRealWindow() {
        guard !closing else { return }
        guard Permissions.accessibility else {
            PinManager.shared.onNeedsPermission?()
            return
        }
        let f = panel.frame
        let target = CGRect(x: f.minX, y: Geometry.primaryHeight - f.maxY, width: f.width, height: f.height)

        if let current = WindowList.bounds(of: source.id),
           let ax = AXHelper.window(pid: source.pid, matching: current) {
            AXHelper.setFrame(ax, to: target)
            AXHelper.raise(ax)
        }
        NSRunningApplication(processIdentifier: source.pid)?.activate()

        handedOff = true
        // Give the app a moment to redraw at its new spot so there's no flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.handedOff, !self.closing else { return }
            self.panel.orderOut(nil)
        }
    }

    /// You switched to another app: float again, right where the real window is now.
    private func reappear() {
        guard !closing else { return }
        handedOff = false
        if let b = WindowList.bounds(of: source.id) {
            panel.setFrame(Geometry.toCocoa(b), display: true)
            mirror.aspect = b.size
        }
        panel.alphaValue = CGFloat(Prefs.opacity)
        panel.orderFrontRegardless()
    }

    private func appActivated(_ note: Notification) {
        guard !closing,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == source.pid {
            // You went to the real app some other way (Dock, ⌘Tab, clicking it).
            if !handedOff {
                handedOff = true
                panel.orderOut(nil)
            }
        } else if handedOff {
            reappear()
        }
    }

    // MARK: Shake to unpin

    private func handleDrag(_ p: NSPoint) {
        guard Prefs.shakeEnabled else { return }
        if shake.feed(p) {
            if Prefs.playSound { NSSound(named: "Bottle")?.play() }
            unpin()
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
        let p = PinnedWindow(source: window)
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
