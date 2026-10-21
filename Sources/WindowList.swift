import AppKit
import ApplicationServices
import CoreGraphics

/// A window owned by some other app. `bounds` uses CoreGraphics coordinates
/// (origin at top-left of the main display, y grows downward).
struct WinInfo {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let owner: String
    let title: String

    var displayName: String { title.isEmpty ? owner : "\(owner) · \(title)" }
}

enum WindowList {
    /// Normal app windows currently on screen, front to back.
    static func onScreen() -> [WinInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let w = parse(info),
                  w.pid != me,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  w.bounds.width >= 80, w.bounds.height >= 60 else { return nil }
            return w
        }
    }

    /// Topmost window under a point (CG coordinates).
    static func window(at point: CGPoint) -> WinInfo? {
        onScreen().first { $0.bounds.contains(point) }
    }

    /// Frontmost window of the frontmost app.
    static func frontmostWindow() -> WinInfo? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return onScreen().first { $0.pid == pid }
    }

    /// Current bounds of a window, or nil if it no longer exists.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = list.first, let w = parse(info), w.id == id else { return nil }
        return w.bounds
    }

    private static func parse(_ info: [String: Any]) -> WinInfo? {
        guard let id = info[kCGWindowNumber as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? Int,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return WinInfo(id: CGWindowID(id),
                       pid: pid_t(pid),
                       bounds: rect,
                       owner: info[kCGWindowOwnerName as String] as? String ?? "Unknown",
                       title: info[kCGWindowName as String] as? String ?? "")
    }
}

enum Geometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// CG (top-left origin) rect -> Cocoa (bottom-left origin) rect.
    static func toCocoa(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Accessibility helpers for moving the real window and bringing it forward.
/// AX uses the same top-left-origin coordinates as CoreGraphics.
enum AXHelper {
    /// Finds the AX window of `pid` whose frame matches `bounds`.
    static func window(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { w in
            guard let f = frame(of: w) else { return false }
            return abs(f.minX - bounds.minX) < 4 && abs(f.minY - bounds.minY) < 4
                && abs(f.width - bounds.width) < 4 && abs(f.height - bounds.height) < 4
        }
    }

    static func setFrame(_ w: AXUIElement, to r: CGRect) {
        var origin = r.origin
        var size = r.size
        guard let pos = AXValueCreate(.cgPoint, &origin),
              let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position, size, position again: some apps clamp size based on where the window is.
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
    }

    static func setPosition(_ w: AXUIElement, to p: CGPoint) {
        var origin = p
        guard let pos = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
    }

    static func isMinimized(_ w: AXUIElement) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    /// Replays a click at a screen point (CG coordinates) so it lands in whatever is there now.
    static func postClick(at p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            e?.post(tap: .cghidEventTap)
        }
    }

    static func raise(_ w: AXUIElement) {
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    /// The window that currently has focus inside an app (not necessarily the frontmost app).
    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func frame(of w: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }
}
