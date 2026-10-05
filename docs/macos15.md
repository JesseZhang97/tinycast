# Maintaining the macOS 15 branch

This branch carries the smallest practical compatibility delta on top of Tinycast's upstream `main`.
It builds with Xcode 26 and the current SDK while retaining a macOS 15 deployment target.

## Syncing upstream

Keep the fork's `main` aligned with upstream and merge it into this branch. A release-aligned
sync fast-forwards `main` to the latest stable tag instead of `upstream/main`:

```sh
git fetch upstream --tags
git switch main
git merge --ff-only v0.11.12   # or upstream/main
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
  which uses `NSVisualEffectView` on macOS 15.
- Apple Intelligence uses Foundation Models and remains available only on macOS 26. Other configured
  AI providers continue to work on macOS 15.
- Apple's directly constructed translation session is macOS 26-only. Translate reports that limitation
  on macOS 15 rather than crashing or preventing the rest of Quick Actions from working.
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

The verifier asserts both application binaries declare a 15.0 floor and that macOS 26-only symbols
remain weak imports. The GitHub Actions workflow runs the same checks after every branch update.
