import AppKit

/// Counts direction reversals along one axis. A reversal only counts once the
/// pointer has travelled `minSwing` back from the furthest point, so small
/// jitter doesn't register as shaking.
private final class AxisShake {
    private var started = false
    private var dir = 0
    private var extreme: CGFloat = 0
    private(set) var reversals: [TimeInterval] = []

    func reset() { started = false; dir = 0; reversals.removeAll() }

    func feed(_ v: CGFloat, _ t: TimeInterval, minSwing: CGFloat, within: TimeInterval) -> Int {
        if !started { started = true; extreme = v; return 0 }
        switch dir {
        case 0:
            if abs(v - extreme) >= minSwing { dir = v > extreme ? 1 : -1; extreme = v }
        case 1:
            if v > extreme { extreme = v }
            else if extreme - v >= minSwing { reversals.append(t); dir = -1; extreme = v }
        default:
            if v < extreme { extreme = v }
            else if v - extreme >= minSwing { reversals.append(t); dir = 1; extreme = v }
        }
        reversals.removeAll { t - $0 > within }
        return reversals.count
    }
}

/// Detects a back-and-forth shake from a stream of positions (either axis).
final class ShakeTracker {
    private let x = AxisShake()
    private let y = AxisShake()

    func reset() { x.reset(); y.reset() }

    /// Returns true once when a shake is detected.
    func feed(_ p: CGPoint) -> Bool {
        let t = ProcessInfo.processInfo.systemUptime
        let swing = CGFloat(Prefs.shakeDistance)
        let within = Prefs.shakeWindow
        let need = Prefs.shakeReversals
        let nx = x.feed(p.x, t, minSwing: swing, within: within)
        let ny = y.feed(p.y, t, minSwing: swing, within: within)
        if nx >= need || ny >= need { reset(); return true }
        return false
    }
}

/// Watches mouse drags in other apps. When you grab a window and shake it,
/// `onArmed` fires right away (for feedback), and `onShake` fires when you
/// let go, with the window at the spot you dropped it.
final class ShakeMonitor {
    var onArmed: (() -> Void)?
    var onShake: ((WinInfo) -> Void)?

    private var monitors: [Any] = []
    private let tracker = ShakeTracker()
    private var target: WinInfo?
    private var armed = false

    func start() {
        stop()
        let specs: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] e in self?.mouseDown(e) }),
            (.leftMouseDragged, { [weak self] e in self?.mouseDragged(e) }),
            (.leftMouseUp, { [weak self] _ in self?.mouseUp() }),
        ]
        for (mask, handler) in specs {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                monitors.append(m)
            }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func location(_ e: NSEvent) -> CGPoint {
        e.cgEvent?.location ?? CGEvent(source: nil)?.location ?? .zero
    }

    private func mouseDown(_ e: NSEvent) {
        tracker.reset()
        armed = false
        target = Prefs.shakeEnabled ? WindowList.window(at: location(e)) : nil
    }

    private func mouseDragged(_ e: NSEvent) {
        guard !armed, let t = target else { return }
        guard tracker.feed(location(e)) else { return }
        // Make sure the window itself moved (you're dragging it, not selecting text in it).
        guard let now = WindowList.bounds(of: t.id),
              abs(now.minX - t.bounds.minX) > 2 || abs(now.minY - t.bounds.minY) > 2 else { return }
        armed = true
        onArmed?()
    }

    private func mouseUp() {
        defer { target = nil; armed = false }
        guard armed, let t = target else { return }
        // Give the window server a beat to settle the window's final position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let b = WindowList.bounds(of: t.id) else { return }
            self?.onShake?(WinInfo(id: t.id, pid: t.pid, bounds: b, owner: t.owner, title: t.title))
        }
    }
}
