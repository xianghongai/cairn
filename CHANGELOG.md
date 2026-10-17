# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project does not yet use versioned releases. Entries are grouped under `Unreleased` until the first release is tagged.

## [Unreleased]

### Added

- `cairn.sh pull` fetches the manifest and files from a private GitHub Gist and writes each entry to its per-platform path (Linux and macOS).
- `replace` strategy writes a whole file. `merge` strategy deep-merges JSON, JSONC, YAML, or TOML into an existing file, keeping existing comments where the underlying tool supports it.
- The manifest's top level is an `entries` object keyed by entry name. Entry names select entries on the command line; an unknown name fails before any write and lists the available names.
- `path` is either a string used on every platform, or an object with `default` and optional `linux`, `macos`, and `windows` keys. The platform's key is used first, then `default`. An entry with neither does not apply on this platform: it is skipped and counted as skipped, not as a failure.
- For `merge` entries, `format` is inferred from the suffix of `remote` (`.json`, `.jsonc`, `.yaml` or `.yml`, `.toml`) when it is omitted. A declared `format` takes precedence over the suffix.
- `rules` object for `merge` entries, with `arrays` and `objects` subkeys. Each has a `default` and `paths` subkeys. Arrays take `replace`, `override`, or `append`; objects take `replace` or `override`.
  - `arrays` defaults to `replace`. `override` keeps the local items in their original order, appends new remote items, and removes duplicates by whole JSON value. `append` adds the remote array after the local array without comparing values, so every run appends again.
  - `objects` defaults to `override`, which layers the remote keys over the local ones and keeps local-only keys. `replace` replaces the local object as a whole.
  - `paths` sets the rule for one value by its exact dotted path and takes precedence over `default`. Keys that contain a dot are not supported in `paths`.
  - A `paths` rule set to `override` or `append` under an object whose rule is `replace` has no effect, so it is reported as a conflict before any write.
  - An empty target file is merged as an empty object.
- Entries can be selected by name on the command line. With no names, every entry is processed.
- `--dry-run` prints the plan without writing anything, including the resolved real target path. It also lists entries that do not apply or would fail, and ends with a summary.
- Path rules: `~` and `~/...` are relative to the home directory; `.` and `./...`, and unprefixed relative paths, are relative to the current directory. A path ending in `/`, or a bare `~` or `.`, names a directory and the file takes the basename of `remote`. Directories are created as needed.
- Target paths are normalised and resolved through symbolic links before a per-platform blacklist check (Linux, macOS). A target in a blacklisted system directory is refused before any write; paths inside the home directory are always allowed.
- In a terminal, an interactive checklist (no entry selected by default) comes before any write. Use the keyboard to choose entries, then the selected ones are written. Every entry prints one result line (written, skipped, or failed) aligned with the checklist. `--yes` runs every entry without the checklist, and is required for non-interactive runs.
- Backups of existing files before they are overwritten or merged, stored under `$XDG_STATE_HOME/cairn/backup/` (or `~/.local/state/cairn/backup/` when it is unset or not an absolute path) with a timestamp in the name.
- Atomic writes through a temporary file in the target directory. Symbolic links are followed, so the link itself is preserved.
- Failures are isolated per entry. The run prints a summary and exits non-zero if any entry failed.
- Manifest validation against `cairn-manifest.schema.json` before any write. Schema validation does not check format inference, which happens at run time.
- `cairn.sh install` copies the script to `~/.local/bin/cairn` without changing shell configuration.
- `cairn.sh --help` describes commands, options, and environment variables.
- Output in English or Simplified Chinese. `CAIRN_LANG` takes a BCP 47 tag (`en` or `zh-CN`); without it, the language follows `LC_ALL`, `LC_MESSAGES`, then `LANG`, and defaults to English.
- The checklist key hints show the keys in colour. Set `NO_COLOR` to turn colour off.
- Dependencies are checked only for the formats an entry needs, with an install hint when a tool is missing.
- Test suite that runs in a network-isolated Docker container under both Bash and Zsh.

### Security

- The GitHub token is read only from the `CAIRN_GITHUB_TOKEN` environment variable. It is passed to `curl` through a file descriptor, so it does not appear in the process list.
