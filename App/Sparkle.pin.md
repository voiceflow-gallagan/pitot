# Sparkle pin

Pitot uses Sparkle for updates. It is the app's only third-party dependency. Core has none.

| Item | Value |
|---|---|
| Version | 2.10.0, exact (`exactVersion` in `App/project.yml`) |
| Git revision | `eef1a539a373c1f1a320624b1130fc5de7b2e100` |
| Binary zip SHA-256 | `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959` |
| Source | https://github.com/sparkle-project/Sparkle |
| License | MIT, with bundled notices. Copied to `App/Resources/Licenses/Sparkle-LICENSE.txt` |

## Where the pin is recorded

- `App/project.yml` asks for exactly 2.10.0.
- `App/Package.resolved` records the revision. Xcode keeps its own copy inside the generated project, which git ignores. `xcodegen generate` copies the committed file into the project after each generation, so a build resolves the recorded revision.
- SwiftPM checks the binary zip against the SHA-256 in Sparkle's tagged `Package.swift`. A different zip fails resolution.

## To change the version

1. Read the release notes and the security advisories.
2. Change `exactVersion` in `App/project.yml`.
3. Run `xcodegen generate` and `xcodebuild -resolvePackageDependencies -scheme Pitot`.
4. Copy `Pitot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` to `App/Package.resolved`.
5. Update this file and the license copy, and review the diff of both.
