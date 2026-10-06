# Customize keyboard shortcuts

> Synthetic test page for catalog-check. It copies the layout of the keybindings page, not its text. The context and action ids are real, the descriptions are written for this test.

## Configuration file

Run `/keybindings` to open the file. Each block names a `context` and maps keys to actions.

```json
{
  "bindings": [
    { "context": "Chat", "bindings": { "ctrl+e": "chat:submit" } }
  ]
}
```

## Contexts

A block applies in one **context**:

| Context | Description |
| :- | :- |
| `Global` | Everywhere |
| `Chat` | The prompt input |
| `Footer` | The footer bar |
| `Plugin` | The plugin list |
| `Scroll` | The conversation view |
| `DiffDialog` | The diff viewer |
| `MessageSelector` | The message picker |

## Available actions

Action ids have the form `namespace:action`.

### App actions

Actions in the `Global` context:

| Action | Default | Description |
| :- | :- | :- |
| `app:interrupt` | Ctrl+C | Stops the current task |
| `app:exit` | Ctrl+D | Quits |
| `app:redraw` | (unbound) | Repaints the screen |

### History actions

Actions for earlier prompts:

| Action | Default | Description |
| :- | :- | :- |
| `history:search` | Ctrl+R | Searches earlier prompts |
| `history:previous` | Up | Shows the prompt before |

### Chat actions

Actions in the `Chat` context:

| Action | Default | Description |
| :- | :- | :- |
| `chat:submit` | Enter | Sends the prompt |
| `chat:stash` | Ctrl+S | Puts the prompt aside |
| `chat:cycleMode` | Shift+Tab\* | Moves to the next permission mode |

\* Some terminals send another key for Shift+Tab.

### Footer actions

Actions in the `Footer` context:

| Action | Default | Description |
| :- | :- | :- |
| `footer:next` | Right | Next footer item |
| `footer:previous` | Left | Previous footer item |

### Plugin actions

Actions in the `Plugin` context:

| Action | Default | Description |
| :- | :- | :- |
| `plugin:favorite` | F | Pins the selected plugin |

### Scroll actions

Actions in the `Scroll` context:

| Action | Default | Description |
| :- | :- | :- |
| `scroll:top` | Ctrl+Home | Goes to the first message |
| `scroll:bottom` | Ctrl+End | Goes to the last message |

The `DiffDialog` context uses other keys for the same actions:

| Action | Default | Description |
| :- | :- | :- |
| `scroll:top` | G, Home | Goes to the top of the diff |
| `scroll:bottom` | Shift+G, End | Goes to the end of the diff |

### Select actions

Actions in the `MessageSelector` context:

| Action | Default | Description |
| :- | :- | :- |
| `select:previous` | Up, K, Ctrl+P | Previous message |
| `select:next` | Down, J, Ctrl+N | Next message |

The old ids `messageSelector:up` and `messageSelector:down` still work.
