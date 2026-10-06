# Model configuration

> Synthetic test page for catalog-check. It copies the layout of the model configuration page, not its text. The aliases are real, the descriptions are written for this test.

## Available models

Set a model with the `model` setting, the `--model` flag or the `/model` command.

### Model aliases

| Model alias | Behavior |
| :- | :- |
| `default` | Clears your choice. It is not itself a model alias |
| `best` | The most capable model |
| `opus` | The latest Opus model |
| `sonnet` | The latest Sonnet model |
| `haiku` | The latest Haiku model |
| `opusplan` | Opus to plan, Sonnet to act |
| `sonnet[1m]` | Sonnet with the long context window |

Add `[1m]` to other aliases too, as in `opus[1m]`.
