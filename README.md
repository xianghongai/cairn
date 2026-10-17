# Cairn

> Cairn (石堆) is a marker of a path left by stacking stones.

[English](README.md) | [简体中文](README.zh-CN.md)

Keep one set of user-level configuration files in a private GitHub Gist, and pull each file to the right place on every machine.

## Why

Your Linux and macOS machines each keep the same configuration files, but:

- **The paths differ**: the same file may live under `~/.config/...` on Linux and under `~/Library/...` on macOS.
- **The formats differ**: plain text, JSON, JSONC, YAML, and TOML all appear in one setup.
- **Some files are fragments**: a settings file may hold a few keys you want to share, while the rest stays local. Copying the whole file overwrites what you do not want to change.

Cairn keeps the files in a private Gist and describes each one in a manifest. `cairn pull` reads the manifest and writes each entry to its local path, using either a full replacement or a merge.

## Features

- **Gist as the single source**: the manifest and the files live in one private Gist. Cairn fetches them at run time and keeps no local copy.
- **Per-platform paths**: one entry can target different paths on Linux and macOS.
- **Two write strategies**: `replace` writes the whole file. `merge` deep-merges a fragment into an existing file.
- **Merge rules per kind of value**: `rules` sets how arrays and objects are merged, with a default and per-path overrides.
- **Comments survive merges**: JSONC, YAML, and TOML merges keep the comments already in the target file.
- **Safe by default**: you choose entries in a checklist before anything is written, every overwrite is backed up, `--dry-run` previews without writing, and writes into system directories are refused.
- **Failures are isolated**: one failing entry does not stop the others. Cairn prints a summary and exits non-zero if anything failed.
- **Easy to fetch**: the script is a single file. Download it with curl or wget and run it, or install it into `~/.local/bin`.

## Requirements

| Tool | Needed for |
| --- | --- |
| Bash or Zsh | Running the script |
| `curl` | Fetching the Gist |
| `jq` | Every run (reads the manifest) |
| `yq` (mikefarah, v4) | YAML merges |
| `python3` with `tomlkit` | TOML merges |
| `node` with `jsonc-parser` | JSONC merges (set `NODE_PATH` to where `jsonc-parser` is installed) |

A format tool is needed only when a `merge` entry uses that format. If it is missing, the error tells you how to install it.

Cairn supports Linux and macOS. Windows is not supported yet.

## Quick start

1. Create a private Gist with a manifest and the files it describes. The manifest format is shown below.
2. [Create a GitHub token](https://github.com/settings/tokens/new?scopes=gist&description=Cairn). The link preselects the `gist` scope needed to read the Gist.
3. Run Cairn:

```sh
export CAIRN_GIST_ID=<gist-id>
export CAIRN_GITHUB_TOKEN=<token>

curl -fsSL https://raw.githubusercontent.com/xianghongai/cairn/main/cairn.sh -o cairn.sh
# or: wget -qO cairn.sh https://raw.githubusercontent.com/xianghongai/cairn/main/cairn.sh

bash cairn.sh pull --dry-run    # preview, write nothing
bash cairn.sh pull              # choose entries in the checklist, then write
```

Run `bash cairn.sh install` to install the script as the `~/.local/bin/cairn` command.

## Manifest

The manifest is a JSON file in the Gist, named `cairn-manifest.json` by default. Its top level is `entries`, an object whose keys are the entry names and whose values describe one file each. The JSON Schema lives in [cairn-manifest.schema.json](cairn-manifest.schema.json); point your editor at it for validation.

```json
{
  "entries": {
    "app-settings": {
      "remote": "example-config.json",
      "path": "~/.config/example/settings.json",
      "strategy": "merge",
      "rules": {
        "arrays": { "default": "override" }
      }
    },
    "app-keys": {
      "remote": "app-keys.conf",
      "path": {
        "default": "~/.config/example/",
        "macos": "~/Library/Application Support/Example/"
      },
      "strategy": "merge",
      "format": "toml",
      "description": "Key bindings, merged into the local file"
    }
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `remote` | yes | File name in the Gist. |
| `path` | yes | Target path. See the path rules below. |
| `strategy` | yes | `replace` or `merge`. |
| `format` | no | `json`, `jsonc`, `yaml`, or `toml`. For `merge`, it is inferred from the suffix of `remote` (`.json`, `.jsonc`, `.yaml`/`.yml`, `.toml`) when omitted. |
| `rules` | no | Merge rules for a `merge` entry. See below. |
| `description` | no | Free text for your reference. |

Path rules:

- A string applies to every platform. An object sets `default` and may override it with `linux`, `macos`, or `windows`. The platform's key wins, then `default`. If neither exists, the entry is skipped on this platform.
- `~` and `~/...` are relative to your home directory. `.`, `./...`, and paths with no prefix are relative to the current directory. Absolute paths are used as is.
- A path that ends in `/`, or a bare `~` or `.`, names a directory. The file is written inside it under the name of `remote`.
- After `..` and symlinks are resolved, a target inside a system directory such as `/etc` or `/System` is refused before anything is written. Paths inside your home directory are always allowed.

## Merge rules

`rules` has two kinds of rule:

- `arrays`: how arrays are merged. Defaults to `replace`.
- `objects`: how objects are merged. Defaults to `override`.

Each kind takes:

- `default`: applies to every value of that kind in the fragment, at any depth.
- `paths`: sets the rule for one value by its full dotted path. Takes precedence over `default`.

The values:

- **`replace`**: the remote value wins, and the local value at that location is replaced as a whole.
  - Objects: local-only keys are removed.
  - Arrays: the local items are replaced by the remote array.
- **`override`**: the local content is kept, and the remote content is layered on top.
  - Objects: remote keys overwrite matching local keys, and local-only keys are kept, recursively.
  - Arrays: local items keep their order, new remote items are appended, and duplicates are removed by whole value.
- **`append`** (arrays only): the remote array is added after the local array as is.
  - Values are not compared and nothing is removed, so equal values can stay as separate items.
  - Every pull appends again, so use it only when each run is meant to add the items.

```json
"rules": {
  "arrays": {
    "default": "override",
    "paths": { "permissions.deny": "replace" }
  },
  "objects": {
    "paths": { "servers.example": "replace" }
  }
}
```

What this example does:

- The `permissions.deny` array is replaced by the remote array.
- Every other array is merged with `override`.
- The `servers.example` object is replaced by the remote object, so its local-only keys are removed.

Details:

- `paths` matches a full path exactly, without wildcards, and applies only to paths that appear in the remote fragment.
- An `override` or `append` path under an object whose rule is `replace` has no effect, and Cairn reports the conflict before writing. To keep it, set every parent object on the way to `override`.
- An empty target file is merged as an empty object.
- The rules are the same for every format.

More examples are in [EXAMPLE.md](EXAMPLE.md).

## Commands

```text
cairn.sh pull [options] [name ...]
cairn.sh install
cairn.sh --help
```

| Option | Meaning |
| --- | --- |
| `--gist ID` | Gist ID. Overrides `CAIRN_GIST_ID`. |
| `--manifest NAME` | Manifest file name in the Gist. Defaults to `cairn-manifest.json`. Overrides `CAIRN_MANIFEST`. |
| `--dry-run` | Preview each entry's strategy and real target path. Write nothing. |
| `--yes` | Write every entry without showing the checklist. Required when there is no terminal. |

Pass entry names to process only those entries, for example `cairn.sh pull app-keys`. With no names, Cairn processes every entry.

| Environment variable | Meaning |
| --- | --- |
| `CAIRN_GIST_ID` | Gist ID. |
| `CAIRN_MANIFEST` | Manifest file name in the Gist. Defaults to `cairn-manifest.json`. |
| `CAIRN_GITHUB_TOKEN` | GitHub token. Read only from the environment, so it stays out of your shell history and the process list. |
| `CAIRN_LANG` | Output language as a BCP 47 tag: `en` or `zh-CN`. When it is not set, Cairn follows `LC_ALL`, `LC_MESSAGES`, then `LANG`: a value starting with `zh` selects Simplified Chinese, and anything else selects English. |
| `NO_COLOR` | When set to a non-empty value, the key hints are shown without colour ([no-color.org](https://no-color.org)). |

Command-line options take precedence over environment variables.

## Safety

- **Checklist**: in a terminal, Cairn lists every entry with its strategy and target path before writing, with none selected. Use the arrow keys or `j`/`k` to move, Space to toggle, `a` to select all, `n` to clear, Enter to write, and `q` or Esc to cancel. Without a terminal, Cairn writes only when you pass `--yes`.
- **Backups**: before an existing file is overwritten or merged, Cairn copies it to `$XDG_STATE_HOME/cairn/backup/` (or `~/.local/state/cairn/backup/` when that is unset or not an absolute path), with a timestamp in the name.
- **Atomic writes**: content goes to a temporary file first and then replaces the target. A failed write leaves the original file in place.
- **Symbolic links**: if a target is a symlink, Cairn writes to the file it points to, and the link stays in place.
- **Validation first**: a malformed manifest stops the run before anything is written.

## Known limits

- A YAML target that contains only comments loses those comments on merge.
- TOML merges use `tomlkit` only. `taplo` cannot perform a deep merge, so it is not used.
- `rules` paths cannot address a key that contains a dot, such as `"a.b"`. The dot is read as a path separator.

## Development

The tests run in Docker. See [test/README.md](test/README.md) for details.

```sh
docker compose -f test/compose.yaml run --build --rm test
```

## License

[MIT](LICENSE)
