import SwiftUI
import ServiceManagement

// MARK: - Permissions onboarding

final class PermissionModel: ObservableObject {
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording
    var onDone: (() -> Void)?
    private var timer: Timer?

    init() {
        // Poll so the checkmarks flip as soon as you grant access in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let ax = Permissions.accessibility
        let sr = Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: PermissionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "pin.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to FloatPin").font(.title2).bold()
                    Text("Grab any window and shake it to keep it on top.")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "When you click a pin, moves the real window to exactly where the pin is and brings it forward.",
                granted: model.accessibility,
                action: Permissions.requestAccessibility)

            PermissionRow(
                title: "Screen Recording",
                detail: "Shows a live copy of the window you pinned. Nothing is saved or sent anywhere.",
                granted: model.screenRecording,
                action: Permissions.requestScreenRecording)

            HStack {
                Text("Granted it but still unchecked? macOS sometimes needs a restart of the app.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch") { Permissions.relaunch() }
            }

            HStack {
                Spacer()
                Button(model.accessibility && model.screenRecording ? "Start Pinning" : "Later") {
                    model.onDone?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(Color.green)
            } else {
                Button("Grant…", action: action)
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(K.shakeEnabled) private var shakeEnabled = true
    @AppStorage(K.shakeReversals) private var reversals = 6
    @AppStorage(K.shakeWindow) private var shakeWindow = 2.0
    @AppStorage(K.shakeDistance) private var shakeDistance = 30.0
    @AppStorage(K.clickThrough) private var clickThrough = false
    @AppStorage(K.showBorder) private var showBorder = false
    @AppStorage(K.frameRate) private var frameRate = 30
    @AppStorage(K.hotkeyEnabled) private var hotkeyEnabled = true
    @AppStorage(K.playSound) private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shake to pin") {
                Toggle("Shake a window to pin it", isOn: $shakeEnabled)
                Stepper("Back-and-forth moves needed: \(reversals)", value: $reversals, in: 2...14)
                Slider(value: $shakeWindow, in: 0.5...3, step: 0.25) {
                    Text("Within \(shakeWindow, specifier: "%.2f") seconds")
                }
                Slider(value: $shakeDistance, in: 10...120, step: 5) {
                    Text("Shake distance: \(Int(shakeDistance)) pt")
                }
                Text("Shake a pinned window again (or click its pin badge) to unpin it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pinned windows") {
                Toggle("Click-through (clicks go to whatever is behind, so clicking a pin won't open it)", isOn: $clickThrough)
                Toggle("Show colored border", isOn: $showBorder)
                Picker("Frame rate", selection: $frameRate) {
                    Text("10 fps").tag(10)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
            }

            Section("General") {
                Toggle("Pin the front window with ⌃⌥P", isOn: $hotkeyEnabled)
                Toggle("Play sounds", isOn: $playSound)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {}
                        let actual = SMAppService.mainApp.status == .enabled
                        if actual != on { launchAtLogin = actual }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
    }
}
