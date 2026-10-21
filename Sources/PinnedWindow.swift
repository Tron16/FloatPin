import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/*
 How a pin behaves (the rule that keeps it feeling like ONE window):

 - The real window is always glued directly underneath the pin: same spot,
   same size. Move or resize the pin and the real window follows live.
 - Only one of them is ever visible:
     * Using anything else      -> the pin shows, floating above everything,
                                   including other windows of the same app
                                   (e.g. a second Chrome window).
     * Using the pinned window  -> the pin tucks away and you use the real window.
 - Click the pin: the real window (already right underneath) comes forward,
   the pin tucks away, and your click is replayed so it lands in the window.
 - Shake it again (pin or real window) to unpin.
*/

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

/// Layer-hosting view that just displays the captured frames.
private final class SurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.backgroundColor = NSColor.clear.cgColor   // the window's own rounded corners show through
        l.cornerRadius = 12
        l.borderColor = NSColor.controlAccentColor.cgColor
        l.borderWidth = 0
        layer = l
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Fills the floating panel: shows the frames, plus a small pin badge on
/// hover, and handles drag-to-move, edge-drag-to-resize and click.
final class MirrorView: NSView {
    var onFirstFrame: (() -> Void)?
    var onClick: ((CGPoint) -> Void)?          // screen point in CG coordinates
    var onDragBegan: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onResize: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onBadgeClick: (() -> Void)?

    /// Width:height of the source window, kept while resizing.
    var aspect = CGSize(width: 16, height: 10)

    var showBorder = false {
        didSet { surface.layer?.borderWidth = showBorder ? 2 : 0 }
    }

    private struct Edges {
        var left = false, right = false, top = false, bottom = false
        var any: Bool { left || right || top || bottom }
    }
    private enum Mode { case idle, move, resize(Edges), badge }

    private let surface = SurfaceView(frame: .zero)
    private let badge = NSView()
    private var mode = Mode.idle
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private var downPoint = CGPoint.zero
    private var moved = false
    private var hovering = false
    private var hadFirstFrame = false
    private let grip: CGFloat = 8
    private let badgeSize: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)

        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        badge.layer?.cornerRadius = badgeSize / 2
        badge.layer?.shadowOpacity = 0.3
        badge.layer?.shadowRadius = 3
        badge.layer?.shadowOffset = CGSize(width: 0, height: -1)
        badge.frame = NSRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
        badge.toolTip = "Unpin"
        if let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Unpin") {
            let iv = NSImageView(image: img)
            iv.contentTintColor = .white
            iv.frame = badge.bounds.insetBy(dx: 6, dy: 6)
            badge.addSubview(iv)
        }
        badge.alphaValue = 0
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        badge.frame.origin = NSPoint(x: bounds.maxX - badgeSize - 12, y: bounds.maxY - badgeSize - 10)
    }

    func show(_ s: IOSurface) {
        surface.layer?.contents = s
        if !hadFirstFrame {
            hadFirstFrame = true
            window?.invalidateShadow()   // shadow follows the window's real shape
            onFirstFrame?()
        }
    }

    // MARK: Badge

    func setBadge(visible: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.badge.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Show the badge briefly right after pinning so you know it worked.
    func flashBadge() {
        setBadge(visible: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, !self.hovering else { return }
            self.setBadge(visible: false)
        }
    }

    // MARK: Events

    // Take every event ourselves (subviews are just for drawing).
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; setBadge(visible: true) }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setBadge(visible: false)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let e = edges(at: p)
        if badge.frame.contains(p) { NSCursor.pointingHand.set() }
        else if (e.left || e.right) && !(e.top || e.bottom) { NSCursor.resizeLeftRight.set() }
        else if (e.top || e.bottom) && !(e.left || e.right) { NSCursor.resizeUpDown.set() }
        else if e.any { NSCursor.crosshair.set() }
        else { NSCursor.arrow.set() }
    }

    private func edges(at p: NSPoint) -> Edges {
        Edges(left: p.x < grip, right: p.x > bounds.width - grip,
              top: p.y > bounds.height - grip, bottom: p.y < grip)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        downPoint = CGEvent(source: nil)?.location ?? .zero
        moved = false
        if badge.alphaValue > 0.5 && badge.frame.contains(p) { mode = .badge; return }
        let e = edges(at: p)
        mode = e.any ? .resize(e) : .move
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x
        let dy = p.y - startMouse.y
        if hypot(dx, dy) > 3 { moved = true }

        switch mode {
        case .idle, .badge:
            return
        case .move:
            guard moved else { return }
            window.setFrameOrigin(NSPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
            onMove?(p)
        case .resize(let e):
            window.setFrame(resized(startFrame, edges: e, dx: dx, dy: dy), display: true)
            onResize?()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasMode = mode
        mode = .idle
        switch wasMode {
        case .badge:
            onBadgeClick?()
        case .move where !moved:
            onDragEnded?()
            onClick?(downPoint)
        case .move, .resize:
            onDragEnded?()
        case .idle:
            break
        }
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

/// One pinned window. See the comment at the top of the file for the rules.
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
    private var axWindow: AXUIElement?
    private var lastSize: CGSize
    private var lastFPS = Prefs.frameRate
    private var timer: Timer?
    private var observers: [Any] = []

    private var closing = false
    private var tucked = false            // hidden because you're using the real window
    private var dragging = false
    private var lastGlue: TimeInterval = 0
    private var lastUserChange: TimeInterval = 0
    private var pendingClick: CGPoint?
    private var focusObserver: AXObserver?

    var title: String { source.displayName }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(source: WinInfo) {
        self.source = source
        self.lastSize = source.bounds.size

        // Exactly on top of the original.
        panel = NSPanel(contentRect: Geometry.toCocoa(source.bounds),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        axWindow = AXHelper.window(pid: source.pid, matching: source.bounds)

        panel.title = source.displayName
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false            // MirrorView moves it so we can glue + watch for shakes
        panel.acceptsMouseMovedEvents = true
        panel.contentView = mirror
        mirror.aspect = source.bounds.size

        mirror.onFirstFrame = { [weak self] in self?.didAppear() }
        mirror.onDragBegan = { [weak self] in
            self?.dragging = true
            self?.shake.reset()
        }
        mirror.onMove = { [weak self] p in
            self?.glue(positionOnly: true)
            self?.handleShake(p)
        }
        mirror.onResize = { [weak self] in self?.glue(positionOnly: false) }
        mirror.onDragEnded = { [weak self] in
            guard let self else { return }
            self.dragging = false
            self.lastUserChange = self.now
            self.glue(positionOnly: false, force: true)
        }
        mirror.onClick = { [weak self] p in self?.handOff(clickAt: p) }
        mirror.onBadgeClick = { [weak self] in self?.unpin() }
        receiver.onFrame = { [weak self] s in self?.mirror.show(s) }
        receiver.onStop = { [weak self] in self?.unpin() }
    }

    // MARK: Lifecycle

    func start() {
        applyPrefs()
        panel.orderFrontRegardless()   // invisible until the first frame arrives
        startStream()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkSource()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                        object: nil, queue: .main) { [weak self] note in
            self?.appActivated(note)
        })
        watchFocus()
    }

    /// First frame is on screen: a little lift so you can see it took, then
    /// step aside if you're still using that window.
    private func didAppear() {
        lift()
        mirror.flashBadge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.closing, !self.dragging else { return }
            self.refreshVisibility()
        }
    }

    private func lift() {
        let f = panel.frame
        let up = f.insetBy(dx: -f.width * 0.015, dy: -f.height * 0.015)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(up, display: true)
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(f, display: true)
            }
        })
    }

    func unpin() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        stopWatchingFocus()
        stream?.stopCapture { _ in }
        stream = nil
        onClose?()

        guard panel.isVisible else { panel.close(); return }
        // Settle back down into the normal window stack.
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            self.panel.animator().setFrame(f.insetBy(dx: f.width * 0.015, dy: f.height * 0.015), display: true)
            self.panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.close()
        })
    }

    // MARK: Settings

    func applyPrefs() {
        guard !closing else { return }
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

    // MARK: Keeping the real window glued under the pin

    private var panelFrameCG: CGRect {
        let f = panel.frame
        return CGRect(x: f.minX, y: Geometry.primaryHeight - f.maxY, width: f.width, height: f.height)
    }

    private func ax() -> AXUIElement? {
        if let axWindow { return axWindow }
        guard let b = WindowList.bounds(of: source.id) else { return nil }
        axWindow = AXHelper.window(pid: source.pid, matching: b)
        return axWindow
    }

    /// Moves (and optionally resizes) the real window to sit exactly under the pin.
    /// Throttled while dragging so the other app isn't flooded.
    private func glue(positionOnly: Bool, force: Bool = false) {
        guard force || now - lastGlue > 0.03, let w = ax() else { return }
        lastGlue = now
        let target = panelFrameCG
        if positionOnly { AXHelper.setPosition(w, to: target.origin) }
        else { AXHelper.setFrame(w, to: target) }
    }

    /// Runs twice a second: unpin if the window closed, follow size changes,
    /// and if something else moved the real window, follow it.
    private func checkSource() {
        guard !closing else { return }
        guard let b = WindowList.bounds(of: source.id) else { unpin(); return }

        if abs(b.width - lastSize.width) > 1 || abs(b.height - lastSize.height) > 1, b.width > 0, b.height > 0 {
            lastSize = b.size
            mirror.aspect = b.size
            stream?.updateConfiguration(makeConfig(size: b.size)) { _ in }
        }

        guard !tucked, !dragging else { return }
        if let w = axWindow, AXHelper.isMinimized(w) { tuck(); return }
        // Right after you move/resize the pin, the real window may still be catching up.
        guard now - lastUserChange > 1 else { return }
        let target = Geometry.toCocoa(b)
        let f = panel.frame
        if abs(target.minX - f.minX) > 2 || abs(target.minY - f.minY) > 2 ||
            abs(target.width - f.width) > 2 || abs(target.height - f.height) > 2 {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: Switching between the pin and the real window

    /// Hide the pin; the real window underneath takes over.
    private func tuck() {
        guard !tucked, !closing else { return }
        tucked = true
        panel.orderOut(nil)
    }

    /// Show the pin again exactly where the real window is now.
    private func untuck() {
        guard tucked, !closing else { return }
        if let w = axWindow, AXHelper.isMinimized(w) { return }
        guard let b = WindowList.bounds(of: source.id) else { unpin(); return }
        panel.setFrame(Geometry.toCocoa(b), display: true)
        mirror.aspect = b.size
        tucked = false
        panel.orderFrontRegardless()
    }

    /// Click on the pin: bring the real window (already right underneath)
    /// forward, then replay the click so it lands in the window.
    private func handOff(clickAt p: CGPoint) {
        guard !closing else { return }
        guard Permissions.accessibility else { PinManager.shared.onNeedsPermission?(); return }
        glue(positionOnly: false, force: true)
        if let w = ax() { AXHelper.raise(w) }
        pendingClick = p
        NSRunningApplication(processIdentifier: source.pid)?.activate()
        // Normally appActivated() finishes this; fall back in case the app was already active.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.finishHandOff() }
    }

    private func finishHandOff() {
        guard let p = pendingClick else { return }
        pendingClick = nil
        tuck()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { AXHelper.postClick(at: p) }
    }

    private func appActivated(_ note: Notification) {
        refreshVisibility()
    }

    /// The one rule: tuck away only while the pinned window itself is the one
    /// you're using. Any other window, even another window of the same app,
    /// gets the pin floating on top of it.
    private func refreshVisibility() {
        guard !closing else { return }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPid == source.pid && isPinnedWindowFocused() {
            if pendingClick != nil { finishHandOff() } else { tuck() }
        } else if pendingClick == nil {
            untuck()
        }
    }

    private func isPinnedWindowFocused() -> Bool {
        guard let focused = AXHelper.focusedWindow(pid: source.pid) else {
            // Can't tell (no Accessibility yet): fall back to "the app is in front".
            return true
        }
        if let mine = ax() { return CFEqual(focused, mine) }
        // No handle on our window: compare frames instead.
        guard let b = WindowList.bounds(of: source.id), let f = AXHelper.frame(of: focused) else { return true }
        return abs(f.minX - b.minX) < 4 && abs(f.minY - b.minY) < 4 && abs(f.width - b.width) < 4
    }

    // MARK: Watching which window of the pinned app has focus

    /// Switching between two windows of the same app doesn't activate a new
    /// app, so listen for the app's own focused-window changes too.
    private func watchFocus() {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<PinnedWindow>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.refreshVisibility() }
        }
        guard AXObserverCreate(source.pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(source.pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = observer
    }

    private func stopWatchingFocus() {
        guard let observer = focusObserver else { return }
        let app = AXUIElementCreateApplication(source.pid)
        AXObserverRemoveNotification(observer, app, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(observer, app, kAXMainWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = nil
    }

    // MARK: Shake to unpin

    private func handleShake(_ p: NSPoint) {
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

    /// Pins the window, or unpins it if it's already pinned.
    func toggle(_ window: WinInfo, sound: Bool) {
        if let existing = pins.first(where: { $0.source.id == window.id }) {
            if Prefs.playSound { NSSound(named: "Bottle")?.play() }
            existing.unpin()
            return
        }
        // Both are needed: Screen Recording to show it, Accessibility to keep the real window glued under it.
        guard Permissions.allGranted else { onNeedsPermission?(); return }
        let p = PinnedWindow(source: window)
        p.onClose = { [weak self, weak p] in
            guard let self, let p else { return }
            self.pins.removeAll { $0 === p }
            self.onChange?()
        }
        pins.append(p)
        p.start()
        if sound && Prefs.playSound { NSSound(named: "Pop")?.play() }
        onChange?()
    }

    func unpinAll() { pins.forEach { $0.unpin() } }

    func applyPrefs() { pins.forEach { $0.applyPrefs() } }
}
