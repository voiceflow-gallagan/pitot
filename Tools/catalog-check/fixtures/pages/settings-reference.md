# All settings

> Synthetic test page for catalog-check. It copies the layout of the settings reference, not its text. The keys are real, the descriptions are written for this test.

## Scopes

| Scope | Where the key can be set |
| :- | :- |
| `Any file` | User, project, local and managed settings |
| `User or managed` | User settings and managed settings only |
| `User, local, or managed` | Every settings file except project settings |
| `Managed` | Managed settings only |
| `Global config` | The global config file, not a settings file |

## Settings index

| Key | Description | Topic | Scope |
| :- | :- | :- | :- |
| [`agent`](#agent) | Agent for the main thread | Agents | Any file |
| [`allowManagedHooksOnly`](#allowmanagedhooksonly) | Run only hooks from managed settings | Hooks | Managed |
| [`alwaysThinkingEnabled`](#alwaysthinkingenabled) | Thinking on by default | Model | Any file |
| [`askUserQuestionTimeout`](#askuserquestiontimeout) | Time limit for question dialogs | Interface | User or managed |
| [`cleanupPeriodDays`](#cleanupperioddays) | Days to keep old sessions | Files | Any file |
| [`editorMode`](#editormode) | Key style of the prompt input | Interface | Any file |
| [`env`](#env) | Environment variables for each session | Environment | Any file |
| [`fastMode`](#fastmode) | Fast output mode | Model | Any file |
| [`fastModePerSessionOptIn`](#fastmodepersessionoptin) | Fast mode resets each session | Model | Any file |
| [`language`](#language) | Reply language | Model | Any file |
| [`maxEffortLevel`](#maxeffortlevel) | Upper limit for effort | Model | Any file |
| [`model`](#model) | Default model | Model | Any file |
| [`outputStyle`](#outputstyle) | Output style | Model | Any file |
| [`permissions.defaultMode`](#permissions-defaultmode) | Starting permission mode | Permissions | Any file |
| [`permissions.disableBypassPermissionsMode`](#permissions-disablebypasspermissionsmode) | Turn off bypass mode | Permissions | Any file |
| [`promptCacheTtl`](#promptcachettl) | Prompt cache lifetime | Model | Any file |
| [`sandbox.enabled`](#sandbox-enabled) | Bash sandbox | Sandbox | Any file |
| [`theme`](#theme) | Color theme | Interface | Any file |
| [`tui`](#tui) | Terminal renderer | Interface | Any file |

## Agents

### `agent`

Runs the main thread as the named subagent.

* **Scope**: [`Any file`](#scopes)
* **Type**: string
* **Default**: unset

## Hooks

### `allowManagedHooksOnly`

When true, only hooks from managed settings run.

* **Scope**: [`Managed`](#scopes)
* **Type**: Boolean
* **Default**: `false`

## Model

### `alwaysThinkingEnabled`

Turns extended thinking on for every session.

* **Scope**: [`Any file`](#scopes)
* **Type**: Boolean
* **Default**: unset, so models that can think do think

### `fastMode`

Turns fast output on.

* **Scope**: [`Any file`](#scopes)
* **Type**: Boolean
* **Default**: unset, fast mode stays off

### `fastModePerSessionOptIn`

Makes fast mode start off in every new session.

* **Scope**: [`Any file`](#scopes)
* **Type**: Boolean
* **Default**: `false`

### `language`

Language for replies.

* **Scope**: [`Any file`](#scopes)
* **Type**: string
* **Default**: unset

### `maxEffortLevel`

Sets the highest effort level a session can use. Requires Claude Code v2.1.267 or later.

* **Scope**: [`Any file`](#scopes)
* **Type**: string, one of `"low"`, `"medium"`, `"high"`, `"xhigh"`, or `"max"`
* **Default**: unset, so there is no limit

### `model`

Default model for new sessions. See [model aliases](/docs/en/model-config).

* **Scope**: [`Any file`](#scopes)
* **Type**: string
* **Default**: unset, so the account default applies

### `outputStyle`

Name of the output style to use.

* **Scope**: [`Any file`](#scopes)
* **Type**: string
* **Default**: unset

### `promptCacheTtl`

Lifetime of cached prompts. Requires Claude Code v2.1.242 or later.

* **Scope**: [`Any file`](#scopes)
* **Type**: string, one of `"5m"` or `"1h"`
* **Default**: unset
* **Providers**: Requires Claude Code v2.1.250 or later for `"1h"` on a cloud provider

## Interface

### `askUserQuestionTimeout`

How long a question dialog waits before it closes.

* **Scope**: [`User or managed`](#scopes)
* **Type**: string, one of:
  * `"60s"`: one minute
  * `"5m"`: five minutes
  * `"10m"`: ten minutes
  * `"never"`: no limit
* **Default**: `"never"`

### `editorMode`

Key style of the prompt input.

* **Scope**: [`Any file`](#scopes)
* **Type**: string, one of `"normal"` or `"vim"`
* **Default**: `"normal"`

### `theme`

Color theme of the interface.

* **Scope**: [`Any file`](#scopes)
* **Type**: string, one of:
  * `"auto"`: follows the terminal
  * `"dark"`: dark colors
  * `"light"`: light colors
  * `"custom:<slug>"`: a theme file you wrote
* **Default**: `"dark"`

### `tui`

Picks the terminal renderer.

* **Scope**: [`Any file`](#scopes)
* **Type**: string, one of:
  * `"default"`: the classic renderer
  * `"fullscreen"`: the fullscreen renderer
* **Default**: unset, so Claude Code picks one

## Files

### `cleanupPeriodDays`

Sessions older than this many days are deleted at startup.

* **Scope**: [`Any file`](#scopes)
* **Type**: number
* **Default**: `30`

## Permissions

### `permissions.defaultMode`

Permission mode at the start of a session.

* **Scope**: [`Any file`](#scopes). Only user and managed settings can choose `bypassPermissions`
* **Type**: string, one of:
  * `"default"`: asks before each new tool
  * `"acceptEdits"`: accepts file edits
  * `"plan"`: reads but does not change files
  * `"bypassPermissions"`: asks nothing
* **Default**: unset, which means `"default"`

### `permissions.disableBypassPermissionsMode`

Stops anyone from turning on bypass mode.

* **Scope**: [`Any file`](#scopes)
* **Type**: the string `"disable"`
* **Default**: unset

## Sandbox

### `sandbox.enabled`

Runs Bash commands in a sandbox.

* **Scope**: [`Any file`](#scopes)
* **Type**: Boolean
* **Default**: `false`

## Environment

### `env`

Environment variables set for every session.

* **Scope**: [`Any file`](#scopes)
* **Type**: object of strings
* **Default**: unset

#### Variables Claude Code ignores in `env`

* Project and local settings cannot set these variables. Set them in your shell, user settings or managed settings:

  * Variables that move Claude Code's own files: `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_TMPDIR`.
  * The `EXAMPLE_PATH_*` family.

* A few variables are ignored from every file, because only the launcher sets them: `CLAUDE_CODE_EXAMPLE_LAUNCH_ONLY`.
