# FloatPin

A menu bar app that keeps any window floating on top. Grab a window, shake it for a second or two, and it pins right where it is, same size, floating over everything.

## Build and run

You need macOS 14+ and the Xcode command line tools (`xcode-select --install`).

```bash
cd FloatPin
chmod +x build.sh
./build.sh install
```

The first launch opens a setup window asking for **Accessibility** and **Screen Recording**. Click Grant, flip the switch in System Settings, and the checkmarks update on their own. If Screen Recording stays unchecked, hit Relaunch.

## Using it

- **Pin:** drag a window by its title bar and shake it back and forth. The pin appears exactly over the original.
- **Move / resize the pin:** drag it anywhere, or drag its edges to resize (it keeps the window's shape).
- **Click the pin:** the real window jumps to exactly where the pin is, at the same size, and comes forward so you can use it. The pin steps aside.
- **Switch to another app:** the pin floats again, right where the real window is.
- **Unpin:** shake the pin the same way, or use the menu bar.
- **⌃⌥P:** pins the front window. **Menu bar → Pin a Window** lists every open window.
- **Settings:** shake sensitivity, opacity, click-through, border, frame rate, launch at login.

## How it works

macOS won't let one app float another app's window, so FloatPin streams the window with ScreenCaptureKit into its own floating `NSPanel`. A pin is a live view, so to type into it you click it: the real window is moved (via Accessibility) to the pin's exact spot and size and brought forward, so it feels like the same window.

| File | What it does |
|---|---|
| `Shake.swift` | Global mouse monitor + shake detection (counts direction reversals) |
| `PinnedWindow.swift` | The floating panel (drag, resize, click hand-off), the ScreenCaptureKit stream, `PinManager` |
| `WindowList.swift` | Finds windows with `CGWindowListCopyWindowInfo`, moves/raises them with Accessibility |
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
