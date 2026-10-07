# Changelog

All notable changes to Pitot are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
