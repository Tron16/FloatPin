# Contributing to FloatPin

Thanks for wanting to help. FloatPin is small on purpose, so most changes are easy to make and easy to review.

## Getting set up

You need macOS 14+ and the Xcode command line tools. There's no Xcode project and no dependencies.

```bash
git clone https://github.com/Tron16/FloatPin.git
cd FloatPin
./build.sh install
```

Rebuilding resets macOS permissions for ad-hoc signed builds. The README's "Build it yourself" section has a one-line reset, or you can sign with your own certificate via `SIGN_IDENTITY`.

## Where things live

- `Sources/Shake.swift`: shake detection on other apps' windows.
- `Sources/PinnedWindow.swift`: the floating panel and the rules that keep it and the real window feeling like one window. Read the comment at the top of this file first.
- `Sources/WindowList.swift`: window lookup (CoreGraphics) and moving/raising windows (Accessibility).
- `Sources/Views.swift`: the setup and settings screens (SwiftUI).
- `Sources/AppDelegate.swift`: the menu bar menu and wiring.

## Sending a change

1. Open an issue first for anything bigger than a bug fix, so we can agree on the approach.
2. Keep pull requests focused on one thing.
3. Make sure `./build.sh` succeeds. CI builds every pull request on macOS.
4. Describe what you changed and how you tested it (which apps you pinned, which macOS version).

## Reporting bugs

Use the bug report template and include your macOS version, the app you were pinning, and what you expected to happen. A screen recording helps a lot.
