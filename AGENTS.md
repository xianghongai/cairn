# AGENTS.md

## Project

Cairn is a single Bash/Zsh script, `cairn.sh`, that pulls user-level config files from a private GitHub Gist and writes them to per-platform paths, by whole-file `replace` or deep `merge` (JSON, JSONC, YAML, TOML). The manifest format is defined by `cairn-manifest.schema.json`. User-facing behaviour is described in `README.md` and `EXAMPLE.md`.

## Commands

- Run the full test suite, which covers syntax checks, `shellcheck`, and the tests under both Bash and Zsh: `docker compose -f test/compose.yaml run --build --rm test`. Both shells must end with `失败 0`.
- Test layout and conventions: `test/README.md`.

## Constraints

- Run and test the script only inside the disposable Docker container. Do not run `cairn.sh` or `test/cairn/tests.sh` on the host.
- The script must run under Bash 3.2 and Zsh: no associative arrays, `mapfile`, `${var,,}`, `local -n`, or `readlink -f`, and no variable named `path`.
- `jq` features are limited to jq 1.6.
- Every user-facing message is written in both languages through `msg '<zh-CN format>' '<en format>' args...`. Reuse an existing template where one fits, and keep field names, values, environment variables, options, commands, and paths untranslated.
- The GitHub token is read only from `CAIRN_GITHUB_TOKEN`. Never add a command-line option for it, and never put it on a command line.
- Tests go through the command line against the Mock Gist and cover business behaviour only: what is written, where, the merge result, backups, exit codes, and validation before any write. Do not test the wording, layout, or alignment of output.
- More conventions are in `CONTRIBUTING.md`.

## Agent skills

### Issue tracker

GitHub Issues: issues live in `xianghongai/cairn` and are managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
