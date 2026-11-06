# Irisin for rootful iOS 12

This tree is Irisin ported, file by file, to iOS 12.2 and later on a rootful
jailbreak (Amethyst, unc0ver, checkra1n, Chimera on iOS 12). The package is
`wiki.qaq.irisin`, architecture `iphoneos-arm`, installing at the system's own
paths: `/Applications/irisin.app`, `/usr/libexec/irisind`,
`/usr/libexec/irisin-install`, `/usr/bin/irisin-cli`,
`/Library/LaunchDaemons/wiki.qaq.irisind.plist`.

The upstream revisions it was taken from are in `Vendor/UPSTREAM-REVISIONS.txt`.

## Building

CI (`.github/workflows/irisin-rootful.yml` at the repository root) builds the
privileged tools, the CLI and the app with Xcode 26 on macOS, checks every
binary's imports against the iOS 12.4 SDK's stubs, and packages the .deb with
`make _package-deb FLAVOR=rootful`. The .deb is in the run's
`irisin-rootful-ios12` artifact.

On a Mac with Xcode 26, `make deb FLAVOR=rootful` does the same; `brew install
dpkg ldid` first.

Off a Mac, `SIL=1 SHIPPING=1 python3 Scripts/ios12/typecheck.py` compiles every
module against an iOS SDK through the mandatory SIL passes, which report what
Xcode's compile does (escaping captures, use before declaration) beyond the
type check.

The import check goes by the dyld bind information, as dyld does: the
prebuilt WCDBSwift imports Swift 6's `Int128` coding requirements weakly
there while its symbol table still calls them strong. The vendored packages
use `#fileID` rather than `#file`, which in their Swift 5 mode would embed
each caller's absolute source path.

## Why 12.2

iOS 12.2 is the first system with the Swift runtime in the OS. Xcode 26 no
longer embeds the runtime in an app, so an earlier floor would need it shipped
by hand.

## What changed, and how

**No Swift concurrency.** iOS 12 cannot run `async`/`await`, actors or `Task`
(the back-deployed concurrency library needs iOS 13). Swift 6.3 still accepts
`async` declarations for an iOS 12 target, so `Scripts/ios12/typecheck.py`
lints every module for them and `check-ios12-imports.py` fails a binary that
references `libswift_Concurrency` or `swift_task_*`.

- Engines (`IrisinShared/Services`, the packages) were made blocking and run on
  background threads; main-thread state is read through
  `DispatchQueue.main.sync`.
- Interface code: `Task { }` became `LegacyMainTask { }`, whose body runs on the
  main thread; each former `await` became `awaitBackground { }`, which runs the
  work on a global queue while the main run loop keeps turning, so the
  interface stays responsive as it did at an `await`.
  `withCheckedContinuation` became `legacyWaitOnMain`, `@TaskLocal`
  `LegacyTaskLocal`. All of it is in `Vendor/LegacyCompat/Concurrency.swift`.
- The main-actor annotations were kept while converting, with the app checked
  under main-actor default isolation so the compiler reported every hop, and
  then removed (`Scripts/ios12/strip_isolation.py`). The shipped build is Swift 5
  language mode without default isolation.

**Frameworks iOS 12 does not have.** Combine is OpenCombine; CryptoKit is
CommonCrypto (`Vendor/LegacyCrypto`); `UTType` is a file-extension enum.

**UIKit after iOS 12.** `Vendor/LegacyCompat` stands in for what the app used:
system colours, SF Symbols (drawn glyph fallbacks), `UIMenu`/`UIAction`
(action sheets on iOS 12, native menus on 15 and later), diffable data
sources, cell registrations, list content and background configurations,
compositional layouts (`LegacySectionLayout`), `UIButton.Configuration`,
`keyboardLayoutGuide`, `String(localized:)` and more. Context menus became a
long press that opens the same actions as a sheet.

**Scenes.** iOS 12 has no `UIScene`; the window, URL opening and user
activities are the app delegate's (`Irisin/Application/AppDelegate+Window.swift`).

**Bootstrap.** `JailbreakRoot` recognizes a bundle in the system's
`/Applications` as rootful (empty prefix), and `PackagedArchitecture` reports
`iphoneos-arm` there. The daemon and the helper already supported a rootful
root. The postinst falls back to `launchctl` and `uicache` where the helper
cannot load the daemon or register the app.

## Left out

- The iPad split interface: iPad shows the tabs as iPhone does.
- Web management (WebUI, IrisinWeb), external clients and the Apple TV launchpad.
- Syntax highlighting in the text reader (Runestone needs iOS 14): plain text.
- Translation of depictions: the system engine it uses arrives with iOS 15, so
  the menu does not appear.
- Test updates from GitHub: upstream publishes no iOS 12 build.
- The unit tests in `IrisinUnitTest` are upstream's and were not ported.

Nothing here has been run on a device yet.
