# keybindings.json

Data table for the keybindings editor. Source: https://code.claude.com/docs/en/keybindings

## Update when the docs change

1. Fetch the page and compare it with `keybindings.json`.
2. Contexts come from the "Contexts" table. Add or remove entries in `contexts`.
3. Actions come from the "Available actions" tables, one section per namespace.
   Each action lists the contexts where it works. The docs name them in the section intro.
   Set `defaultKey` to the docs text. Leave it out when the docs say "(unbound)".
4. Key rules come from "Keystroke syntax". Reserved keys come from "Reserved shortcuts".
5. Set `researchDate` and `claudeCodeVersionChecked`.
6. Run `swift test --filter Keybindings` in `Core`. The data test lints the file.

## Known gaps in the docs

- The History actions section names no context, so those actions have an empty `contexts` list.
- The `Pane` and `PaneField` contexts have no listed actions.
- Caps Lock is reserved but cannot be written as a key string, so it is not in `reservedKeys`.
- Function keys are not mentioned. Their support is unknown.
- `defaultKey` is display text and is not linted as a key string.
