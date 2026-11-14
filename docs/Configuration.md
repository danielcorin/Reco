# Configuration

Reco keeps all non-secret runtime preferences in one human-readable TOML file.
The app UI and the `reco` command both read and write the same validated store,
so changes made in either place stay in sync.

## Location

Reco follows the XDG Base Directory convention:

```text
$XDG_CONFIG_HOME/reco/config.toml
```

If `XDG_CONFIG_HOME` is unset, empty, or relative, Reco falls back to:

```text
~/.config/reco/config.toml
```

Run `reco config path` to print the effective path. The directory is created
with mode `0700`, and the file with mode `0600`.

## File format and defaults

The file uses [TOML 1.0](https://toml.io/en/v1.0.0). It is optional: when it is
missing, Reco uses its built-in defaults. Reco stores only values that differ
from those defaults, which keeps the file small and lets new defaults take effect
without rewriting user configuration.

The current schema is:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `hotkey` | string | `"control+e"` | Global record shortcut. |
| `show-menu-bar-icon` | boolean | `true` | Whether Reco appears in the menu bar. |

For example:

```toml
hotkey = "shift+command+space"
show-menu-bar-icon = false
```

Hotkeys require at least one modifier and one supported key. Modifier aliases
such as `cmd`, `ctrl`, and `alt` are accepted and written back canonically.
Unknown keys, wrong TOML types, and invalid values are rejected.

## Command line

Open Reco's menu and choose **Install…** beside **Command line** to link the
bundled helper at `~/.local/bin/reco`. Ensure that directory is on `PATH`, then
use:

```sh
reco config path
reco config get hotkey
reco config set hotkey command+shift+space
reco config set show-menu-bar-icon false
reco config unset hotkey
reco config list
reco config list --all
reco config validate
reco config validate ./candidate.toml
reco config reload
```

`list` shows persisted overrides; `list --all` shows every effective value and
whether it came from `defaults` or `user`. `set` validates before writing, and
setting a key to its built-in default removes that override. `unset` also restores
the default. Every command accepts `--json`; usage errors exit with status 2 and
other failures with status 1.

Configuration commands do not need Reco to be running. When it is running,
successful `set`, `unset`, and `reload` commands notify the app immediately.

## Editing the file directly

Reco watches the configuration directory, including atomic file replacements,
and reloads valid manual edits. If an edit is invalid, Reco retains the last
valid settings and shows the validation error in its menu. Fix the file and run
`reco config validate` or `reco config reload` to confirm it.

Writes made by Reco or its CLI are atomic. When the final override is removed,
Reco removes the now-empty configuration file; the absence of the file simply
means “use defaults.”

## Vocabulary

Words Reco listens for live in a second file beside the configuration:

```text
$XDG_CONFIG_HOME/reco/vocabulary.toml   (default ~/.config/reco/vocabulary.toml)
```

It sits with `config.toml` rather than with the usage stats so that it travels
with your configuration. The file is optional; a missing file means an empty
vocabulary. Each word is an `[[term]]` table:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `text` | string | required | The word or phrase as it should be written, up to 64 characters. |
| `heard` | array of strings | `[]` | Spellings the model wrote instead. Each belongs to one term. |
| `source` | `"taught"` or `"learned"` | `"taught"` | Whether you added it or Reco learned it from a correction. |

```toml
[[term]]
text = "Reco"
heard = ["Rico", "eco"]
source = "taught"

[[term]]
text = "FluidAudio"
source = "taught"
```

Reco swaps a transcribed word for a term only when the vocabulary-boosting
model's acoustic evidence supports the term, and only for close spellings or a
listed `heard` spelling, so "Puerto Rico" stays as it is even with "Reco" in the
vocabulary. A word that matches a term apart from case takes the term's casing.

Reco writes learned terms itself. A learned term exists only for its `heard`
spellings: removing the last one removes the term, and if you change a learned
fix back in a document, Reco removes that spelling. Taught terms change only
when you change them. Matching is case-insensitive and terms are kept in the
order they were added.

Manage the file from the menu (**Teach…**, **Edit**), with `reco vocab`, or in
a text editor:

```sh
reco vocab [list] [--json]
reco vocab add <word> [--heard <spelling>]... [--json]
reco vocab remove <word> [--heard <spelling>]... [--json]
reco vocab path [--json]
```

Reco rereads the file before every dictation, so edits take effect right away
without a reload. Unknown keys and invalid values are rejected, and the menu
shows the error until the file is fixed. Writes are atomic, the file has mode
`0600`, and Reco deletes it when the last term is removed.

## Migration and security

On first launch after upgrading, Reco migrates the previous hotkey and menu-bar
visibility values from `UserDefaults` if no TOML file exists. After a successful
load, the legacy values are removed.

The TOML file is intended for ordinary user preferences, not credentials. Store
secrets in macOS Keychain. Developer signing values remain in the ignored
`Configuration/Local.xcconfig`, and release credentials remain in Keychain or
the ignored `.env` file.
