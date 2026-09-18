# AGENTS.md — Sora (Sulfur)

Native iOS/iPadOS 15+ (and macOS) modular media player. SwiftUI + JavaScriptCore:
external JS modules scrape media (spec: https://soradocs.readthedocs.io/en/latest/).

## Layout

- `Sulfur.xcodeproj` — Xcode project (NOT SPM). App target **`Sulfur`**
  (product `Sulfur.app`, Swift module name **`Sulfur`**, bundle `me.cranci.sulfur`,
  Swift **5.0** language mode, iOS 15 deployment, Xcode 26 / iOS 26.5 SDK).
- `Sora/` — all app sources. Entry: `Sora/SoraApp.swift` (wires
  `Settings`, `ModuleManager`, `LibraryManager`, `DownloadManager`, `JSController`).
- `Sora/Utlis & Misc/JSLoader/` — scraping engine. `SoraJSEngine.swift` owns the
  `JSContext`; `JSBridge.swift` injects `fetch`/`fetchv2`/`soraRequest`/`btoa`/`atob`,
  SwiftSoup DOM helpers, P.A.C.K.E.R. deobfuscator, `soraWebFetch` (WKWebView);
  `JSExecutionMode.swift` implements Normal/Async/StreamAsync/SoftSubs;
  `SoraModuleProtocol.swift` = module instance/registry/loader/coordinator;
  `JSController.swift` is the **compat façade all Views use — keep its
  completion-handler APIs stable**; `Downloads/` is download machinery, do not refactor.
- `Sora/Utlis & Misc/Modules/` — `ModuleSpec.swift` (`ModuleMetadata`,
  `ScrapingModule`, `ExecutionMode`); `ModuleManager.swift` persists
  `Documents/modules.json`, throws `NSError` (no custom error enum).
- `Sora/Utlis & Misc/ViewModifiers/GlassDesign.swift` — `GlassTheme` +
  `.adaptiveGlass()` (Liquid Glass only on iOS 26+, navigation layer only).
- `SoraTests/` (`SoraEngineTests.swift`) + shared scheme `Sulfur` (with Test action).

## Commands

```bash
# resolve packages (SwiftSoup is branch-based)
xcodebuild -resolvePackageDependencies -project Sulfur.xcodeproj

# build / test (no valid certs locally: foreign team USF65A4WGS)
xcodebuild -project Sulfur.xcodeproj -scheme Sulfur \
  -destination 'platform=iOS Simulator,id=<UDID>' CODE_SIGNING_ALLOWED=NO [build|test]

# simulators (fresh envs have NO runtime; platform download is ~8.5 GB)
xcrun simctl list runtimes
xcodebuild -downloadPlatform iOS   # if platform missing
xcrun simctl create "NAME" <devicetype> <runtime> && xcrun simctl boot <UDID>
```

Fast full-app check without a full build (needs one prior xcodebuild so package
`.swiftmodule`s exist under `~/Library/Developer/Xcode/DerivedData/Sulfur-*/…`):

```bash
BASE=/Users/gloom/Library/Developer/Xcode/DerivedData/Sulfur-fukxnadgpxnzlkavjslfxblbltfv/SourcePackages/checkouts
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk
swiftc -typecheck -sdk $SDK -target arm64-apple-ios15.0 -swift-version 5 -D DEBUG \
  -enable-bare-slash-regex -enable-experimental-feature DebugDescriptionMacro \
  -I $BASE/{Nuke,Drops,MarqueeLabel,SoraCore,SwiftSoup}/build/Release-iphoneos \
  Sora/**/*.swift
```

## Gotchas (all verified the hard way)

- Tests use `@testable import Sulfur` (never `Sora`). Test classes touching the
  engine must be `@MainActor`. XCTest swiftmodule is at
  `Platforms/iPhoneOS.platform/Developer/usr/lib` (pass `-I`, `-F …/Library/Frameworks`
  alone is not enough); tests also need `-enable-testing` on the app module.
- The app defines its own `Logger` class (private init) shadowing `os.Logger`:
  new files must use `os.Logger` + `import os`.
- Setting `JSContext.exceptionHandler` stops `context.exception` from being
  populated — mirror it manually (see `SoraJSEngine.lastException`).
- JS regex inside Swift raw strings: `\s` in a JS **template literal** cooks to
  `s` — write `[\\s\\S]`; regex literals are unaffected.
- SPM: SwiftSoup's branch is **`master`** (no `main`); a new package ref also
  needs a `packageReferences` entry or you get "Missing package product".
- pbxproj edits: 24-hex IDs, keep FileRef/BuildFile/group/phase/target/config
  refs consistent; verify with `plutil -lint` + per-ID `grep -c`.
- `@MainActor` types (`JSController`, engine): sync nonisolated callers must hop —
  `Thread.isMainThread` guard + `DispatchQueue.main.sync` (off-main only) or
  `.async`, then `MainActor.assumeIsolated`. `os.Logger` interpolation captures
  self → use explicit `self.` inside interpolated strings.
- `URLSession.custom` is an **app-target** extension, usable from new engine files.
- Deployment is iOS 15: gate iOS 26 APIs (`glassEffect`) with `if #available`.
- `ModuleMetadata.version` decodes String-or-Int (docs say integer, wild has both).
- Shell: quote paths (`Utlis & Misc` has `&`); use `workdir`, never `cd`. zsh:
  `~` does not expand after `$var` (use absolute paths); avoid bare `===`;
  `Sora/**/*.swift` glob works.
- `/var/folders/…/T/opencode` is wiped by the system — nothing durable there.
- The user edits the tree live: re-check `git status`/`git diff` when a file's
  state matters, and verify subagent reports (reads/greps) before trusting them.
- Never commit/push/PR unless explicitly asked. Never create docs unless asked.
