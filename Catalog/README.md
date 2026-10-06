# Catalog

`tweaks.json` lists every Claude Code setting and env var that Pitot can edit. The app builds its screens from it.

## Add a row

1. Find the key in the official docs: https://code.claude.com/docs/en/settings-reference or `/env-vars`.
2. Copy a similar row in `tweaks.json`. Fill every field: type, default, plain description, category, risks, scope, notes.
3. Set `docURL` to the doc page and anchor for the key. It must start with `https://code.claude.com/docs/`.
4. Add `minVersion` only if the docs state one.
5. Add `confirm` text if the row has a security or privacy risk.
6. Update `researchDate` and `claudeCodeVersionChecked` in the file header when you recheck the docs.
7. Run `swift test --filter CatalogData` in `Core`. A lint error fails the file.

## Rules

- Every row needs a doc link and a research date. The header date covers the whole file.
- Only rows with status `documented` are allowed. Hidden or unverified keys do not belong in this file.
- If an enum or default is unclear in the docs, leave the row out.
- A flag row is on for any non-empty value. Never use `0` as its off value.

## unverified.json

`unverified.json` lists key names that Claude Code reads but the docs do not describe. It holds names only, with their kind (setting or env var), a status and where the name was seen. It has no descriptions.

- Listing a name is not an endorsement. These keys may change or disappear in any Claude Code release.
- Pitot shows them read-only and never edits them. The app only says whether your files contain them.
- Internal keys and feature flags are left out.
- When the docs start describing a key, `Tools/catalog-check` reports it. Move it to `tweaks.json` as a documented row and remove it here.
