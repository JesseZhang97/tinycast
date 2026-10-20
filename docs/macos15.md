# Maintaining the macOS 15 branch

This branch carries the smallest practical compatibility delta on top of Tinycast's upstream `main`.
It builds with Xcode 26 and the current SDK while retaining a macOS 15 deployment target.

## Syncing upstream

Keep the fork's `main` aligned with upstream and merge it into this branch. A release-aligned
sync fast-forwards `main` to the latest stable tag instead of `upstream/main`:

```sh
git fetch upstream --tags
git switch main
git merge --ff-only v0.12.1   # or upstream/main
git push origin main
git switch macos15
git merge main
./Scripts/verify-macos15.sh
```

Resolve conflicts only on `macos15`; never add compatibility changes to the mirror branch. A new
availability error usually means upstream adopted another macOS 26 API. Put its fallback behind one
`#available(macOS 26.0, *)` boundary and keep the modern path unchanged.

## Compatibility boundaries

- Liquid Glass remains native on macOS 26. macOS 15 renders the same shapes with material, frost,
  border and elevation fallbacks from `Theme.swift`. Panel backdrops go through `GlassEffectView`,
  which uses `NSVisualEffectView` on macOS 15. Call sites use `frosted` / `frostedMenu` /
  `frostedPanel` / `glassButtonStyle()`, never a raw `.glassEffect` or `.buttonStyle(.glass)`.
- Apple Intelligence uses Foundation Models and remains available only on macOS 26. Other configured
  AI providers continue to work on macOS 15. Status goes through `AIProviderFactory.appleIntelligenceStatus()`,
  which reports `.unsupportedOS` below macOS 26.
- Apple's directly constructed translation session is macOS 26-only. Translate reports that limitation
  on macOS 15 rather than crashing or preventing the rest of Quick Actions from working.
- Typed `NotificationCenter` observers (`addObserver(of:for:)`, `DidTerminateApplicationMessage`)
  are macOS 26-only. macOS 15 uses `addObserver(forName:object:queue:)` with the same names.
- The release build is universal because macOS 15 still runs on Intel.

## Verification

Run the quick arm64 Debug check while resolving conflicts:

```sh
./Scripts/verify-macos15.sh --quick
```

Before tagging, run the full harnesses, lint and universal Release verification:

```sh
./Scripts/run-tests.sh
./Scripts/lint.sh
./Scripts/verify-macos15.sh
```

The verifier asserts the app and its embedded helpers declare a 15.0 floor and that macOS 26-only
symbols remain weak imports. The GitHub Actions workflow runs the same checks on `macos-26`, builds
an unsigned universal DMG artifact, and also builds, tests and smoke-launches the app on a real
`macos-15` runner so a missing weak import cannot hide behind the 26 SDK.
