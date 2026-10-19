# Changelog

All notable changes to Pitot are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Nine new catalog rows from the Claude Code 2.1.303 docs: idle compaction and its token limit, web search refills, overloaded retry delays, file mentions, terminal images, Claude in Chrome and artifact publish edits.
- Claude in Chrome can be turned on only in user settings, and turning it on asks you to confirm.
- Keybindings for the area above the prompt and for panes, plus `footer:close`.

### Changed

- `footer:up` and `footer:down` now also use Ctrl+P and Ctrl+N, as the docs say.
- `enableArtifact` no longer needs a minimum Claude Code version.
- The catalog checker reads a "requires" version line in lower case, and it gives a keybinding context only to the actions its sentence names.

## [0.1.3] - 2026-10-07

### Security

- A feed that fails its signature check is now never shown, even after 20 days. Before, Sparkle showed such a feed in a restricted mode after 20 days. Pitot sets `SUSignedFeedFailureExpirationInterval` to 0, so signature failures never expire.
- `SECURITY.md` now explains how update trust works and its limits.

## [0.1.2] - 2026-10-07

### Added

- Menus and shortcuts: Choose Project Folder (Cmd+O), Apply (Cmd+Return), Discard (Cmd+Delete), Undo Last Change, Find (Cmd+F), sections on Cmd+1 to Cmd+7, and a Help menu with links.
- Pitot reopens the last section, scope and project.

### Changed

- Clearer text for empty screens, banners and notes. "Effective" is now "In effect".
- Better accessibility: badge text meets 4.5:1 contrast, headings are marked for VoiceOver, review lines are spoken as "Warning" or "Problem", and Increase Contrast adds stronger outlines.

## [0.1.1] - 2026-10-07

### Fixed

- The project menu no longer shows on the Keybindings screen, where it did nothing.

## [0.1.0] - 2026-10-07

First public release.

### Added

- Settings catalog of 33 documented tweaks, with dependency and version rules.
- Project and local scope, with the effective value shown for each setting.
- Managed settings lock, shown read-only.
- Setup questions with presets, and a diff before each write.
- Keybindings editor.
- Read-only list of undocumented keys.
- Backups and undo for every change.
- Signed and notarized build. Updates use Sparkle and stay off until you opt in.
