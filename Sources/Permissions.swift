import AppKit
import ApplicationServices
import CoreGraphics

/// Checks and requests the two permissions FloatPin needs.
enum Permissions {
    /// Accessibility: lets us raise/focus other apps' windows.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Screen Recording: lets ScreenCaptureKit stream another app's window.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    static var allGranted: Bool { accessibility && screenRecording }

    static func requestAccessibility() {
        // Passing the prompt option adds FloatPin to the list in System Settings
        // and shows the system dialog the first time.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings("Privacy_Accessibility")
        }
    }

    static func requestScreenRecording() {
        // Shows the system prompt the first time; after that it just returns false.
        if !CGRequestScreenCaptureAccess() {
            openSettings("Privacy_ScreenCapture")
        }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen Recording often only takes effect after the app restarts.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
