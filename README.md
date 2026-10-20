# FloatPin

A menu bar app that keeps any window floating on top. Grab a window, shake it for a second or two, and a live copy pins itself to the corner of your screen.

## Build and run

You need macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
cd FloatPin
chmod +x build.sh
./build.sh install
```

The first launch opens a setup window asking for **Accessibility** and **Screen Recording**. Click Grant, flip the switch in System Settings, and the checkmarks update on their own. If Screen Recording stays unchecked, hit Relaunch.

## Using it

- **Pin:** drag a window by its title bar and shake it back and forth.
- **Unpin:** shake the pinned copy the same way, click its close button, or use the menu bar.
- **Double-click a pin:** jumps to the real window. The pin hides while that app is in front and comes back when you switch away.
- **⌃⌥P:** pins the front window.
- **Menu bar → Pin a Window:** pick any open window from a list.
- **Settings:** shake sensitivity, pin size, opacity, click-through, border, frame rate, launch at login.

## How it works

macOS won't let one app float another app's window, so FloatPin streams the window with ScreenCaptureKit into its own floating `NSPanel`. That means a pin is a live view, not the real window: you can watch it but you can't type into it.

| File | What it does |
|---|---|
| `Shake.swift` | Global mouse monitor + shake detection (counts direction reversals) |
| `PinnedWindow.swift` | The floating panel, the ScreenCaptureKit stream, `PinManager` |
| `WindowList.swift` | Finds windows with `CGWindowListCopyWindowInfo`, raises them with Accessibility |
| `Permissions.swift` | Permission checks, prompts, deep links into System Settings |
| `Views.swift` | SwiftUI setup and settings screens |
| `HotKey.swift` | Global ⌃⌥P shortcut |
| `AppDelegate.swift` | Menu bar menu and wiring |

## Troubleshooting

- **Permissions look on but nothing works after a rebuild:** ad-hoc signed builds get a new identity every time. Reset and re-grant:
  `tccutil reset Accessibility com.ashish.FloatPin && tccutil reset ScreenCapture com.ashish.FloatPin`
  Or build with `SIGN_IDENTITY="Apple Development: you@example.com (XXXX)" ./build.sh install` to keep them.
- **macOS 15+ asks again about screen recording:** that's normal for apps using it. Allow it.
- **Shake doesn't trigger:** lower "Back-and-forth moves needed" or "Shake distance" in Settings.
