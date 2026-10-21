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

- **Pin:** grab a window by its title bar and shake it. You'll hear a pop; let go and it's pinned right where you dropped it. It lifts slightly and a little orange pin badge shows for a second so you know it took.
- **It's still one window.** While you're using that app, you're using the real window. Switch to anything else and it stays floating on top.
- **Move / resize it** while it's floating: drag it anywhere or drag its edges. The real window follows along underneath, so nothing gets left behind.
- **Click it** and you're straight back in the real window, and that click goes through (press a button, place the cursor, whatever you clicked).
- **Unpin:** shake it again, click the pin badge (shows on hover), or use the menu bar.
- **⌃⌥P** pins or unpins the front window. **Menu bar → Pin a Window** lists every open window.
- **Settings:** shake sensitivity, click-through, border, frame rate, launch at login.

## How it works

macOS won't let one app float another app's window, so FloatPin streams the window with ScreenCaptureKit into its own floating `NSPanel`. The real window is kept glued directly under the pin (via Accessibility), and only one of the two is ever visible: the pin while you're in other apps, the real window while you're in that app. That's what makes it feel like a single window.

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
