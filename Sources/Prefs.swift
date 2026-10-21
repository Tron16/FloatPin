import Foundation

/// UserDefaults keys. SettingsView uses the same keys through @AppStorage.
enum K {
    static let shakeEnabled = "shakeEnabled"
    static let shakeReversals = "shakeReversals"
    static let shakeWindow = "shakeWindow"
    static let shakeDistance = "shakeDistance"
    static let opacity = "opacity"
    static let clickThrough = "clickThrough"
    static let frameRate = "frameRate"
    static let showBorder = "showBorder"
    static let hotkeyEnabled = "hotkeyEnabled"
    static let playSound = "playSound"
}

enum Prefs {
    static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            K.shakeEnabled: true,
            K.shakeReversals: 6,       // back-and-forth direction changes needed
            K.shakeWindow: 2.0,        // ...within this many seconds
            K.shakeDistance: 30.0,     // each swing must be at least this many points
            K.opacity: 1.0,
            K.clickThrough: false,
            K.frameRate: 30,
            K.showBorder: false,
            K.hotkeyEnabled: true,
            K.playSound: true,
        ])
    }

    static var shakeEnabled: Bool { d.bool(forKey: K.shakeEnabled) }
    static var shakeReversals: Int { max(2, d.integer(forKey: K.shakeReversals)) }
    static var shakeWindow: Double { max(0.3, d.double(forKey: K.shakeWindow)) }
    static var shakeDistance: Double { max(5, d.double(forKey: K.shakeDistance)) }
    static var opacity: Double { min(1, max(0.1, d.double(forKey: K.opacity))) }
    static var clickThrough: Bool { d.bool(forKey: K.clickThrough) }
    static var frameRate: Int { max(1, d.integer(forKey: K.frameRate)) }
    static var showBorder: Bool { d.bool(forKey: K.showBorder) }
    static var hotkeyEnabled: Bool { d.bool(forKey: K.hotkeyEnabled) }
    static var playSound: Bool { d.bool(forKey: K.playSound) }
}
