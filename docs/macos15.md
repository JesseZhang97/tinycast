# Maintaining the macOS 15 branch

This branch carries the smallest practical compatibility delta on top of Tinycast's upstream `main`.
It builds with Xcode 26 and the current SDK while retaining a macOS 15 deployment target.

The fork's `main` is the macOS 15 working branch. It is not an upstream mirror: never fast-forward
or push upstream history onto it.

## Syncing upstream

Cut a `sync/` branch from `main` and merge the upstream stable tag into it. Never rebase or rewrite
the merge:

```sh
git fetch upstream --tags
git switch main
git switch -c sync/v0.12.8
git merge --no-ff v0.12.8
./Scripts/verify-macos15.sh
```

Resolve conflicts by keeping upstream's code and re-applying the compatibility pattern. A new
availability error usually means upstream adopted another macOS 26 API. Put its fallback behind one
`#available(macOS 26.0, *)` boundary and keep the modern path unchanged. Open a PR from the `sync/`
branch into `main`.

## Compatibility boundaries

- Liquid Glass remains native on macOS 26. macOS 15 renders the same shapes with material, frost,
  border and elevation fallbacks from `Theme.swift`. Panel backdrops go through `GlassEffectView`,
  which uses `NSVisualEffectView` on macOS 15. Call sites use `frosted` / `frostedMenu` /
  `frostedPanel` / `glassButtonStyle()`, never a raw `.glassEffect` or `.buttonStyle(.glass)`.
  Compact-bar morphing goes through `GlassGrouping`, which is `GlassEffectContainer` on macOS 26.
- Apple Intelligence uses Foundation Models and remains available only on macOS 26. Other configured
  AI providers continue to work on macOS 15. Status goes through `AIProviderFactory.appleIntelligenceStatus()`,
  which reports `.unsupportedOS` below macOS 26. Type checks go through
  `AIProviderFactory.isAppleIntelligence(_:)`, which is false below macOS 26.
- Apple's directly constructed translation session is macOS 26-only. Translate reports that limitation
  on macOS 15 rather than crashing or preventing the rest of Quick Actions from working.
- Typed `NotificationCenter` observers (`addObserver(of:for:)`, `DidTerminateApplicationMessage`)
  are macOS 26-only. macOS 15 uses `addObserver(forName:object:queue:)` with the same names.
- `NetworkListener` is macOS 26-only. MCP OAuth keeps the modern path behind one availability
  boundary and uses `NWListener` below macOS 26. The OpenCode MCP bridge uses a POSIX loopback
  listener there: `NWListener` with an ephemeral port never leaves setup on macOS 15. A seam a
  standalone harness exercises uses `ProcessInfo`, because those harnesses compile at the 26 SDK floor.
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
`macos-15` runner so a missing weak import cannot hide behind the 26 SDK. Standalone harnesses
compile at the 26 SDK floor, so `#available(macOS 26.0, *)` is folded true there; a runtime seam
those harnesses exercise must use `ProcessInfo` (or an equivalent check the compiler cannot drop).
