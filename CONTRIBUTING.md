# Contributing to Pitot

Pitot is a native macOS app that edits Claude Code settings files.

## Before you start

- Open an issue before you start anything big. We can agree on the approach first.
- Pitot edits only settings that the official Claude Code docs describe.
- A key that is not documented is never a toggle. It can only appear in the read-only list.

## Build from source

You need Xcode 27 with Swift 6 and XcodeGen.

```bash
brew install xcodegen
cd App
xcodegen generate
xcodebuild -scheme Pitot -destination 'platform=macOS' build
```

## Run the tests

```bash
cd Core && swift test                                                   # core logic
cd App && xcodegen generate && xcodebuild -scheme Pitot -destination 'platform=macOS' test
cd Tools/oracle && npm ci && node run.js --check                        # compares JSON edits with jsonc-parser
cd Tools/catalog-check && npm ci && node --test                         # unit tests of the catalog check
cd Tools/catalog-check && node check.js                                 # compares the catalog with the live docs
cd Tools/conformance && swift test                                      # expected values, no Claude Code needed
```

`swift run conformance` in `Tools/conformance` runs Claude Code itself. It uses the Haiku model and costs a few cents of Claude usage per run. It is optional.

## Project layout

- `Core/`: Swift package with no UI. The JSON editor, safe writes, undo, layer merge, catalog loader.
- `App/`: the SwiftUI app. The Xcode project is generated from `App/project.yml`.
- `Catalog/`: data files for the documented settings, setup questions, keybindings and undocumented key names.
- `Fixtures/`: settings files for the Core tests.
- `Tools/`: test oracle, catalog check, conformance test, icon generator, release scripts.

## Rules for changes

- Write the test first, then the code.
- Build with zero warnings.
- Do not use force-unwrap (`!`) or `try!`.
- Code must pass Swift 6 strict concurrency.
- Text in the UI uses plain language. Short sentences, no jargon.

## Catalog rules

These apply to everything in `Catalog/`. See `Catalog/README.md` for the steps.

- Every row in `tweaks.json` needs a documentation link and a research date.
- Write descriptions in your own words. Never copy text from the docs.
- Hidden or unverified keys go only in `unverified.json`. Add the name and where it was seen. Do not add a description.
- Run `Tools/catalog-check` before a pull request that touches `Catalog/`.

## Data safety

- Tests never touch real files in `~/.claude`. They work in temporary folders.
- Fixtures are synthetic. Do not copy a real settings file into the repo.
- Do not paste real settings into issues or pull requests.
- Remove secrets and personal paths from every log you paste.

## Commit style

- Write a short subject in the imperative mood, for example "fix: hide the project menu".
- Explain why the change is needed in the body.

## Security issues

Do not open a public issue for a security problem. Follow `SECURITY.md` and use the private form.

## Forks

If you build your own release, change the bundle id, the team id, the update feed URL and the update signing key. See `Tools/release/README.md`.

## License

Pitot is released under the MIT license. Your contribution is under the same license.
