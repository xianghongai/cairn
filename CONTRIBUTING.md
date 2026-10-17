# Contributing to Cairn

Thanks for considering a contribution. This document describes how to set up a development environment, how to run the tests, and what a change needs before it can be merged.

Participation in this project is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## What belongs here

Cairn is one Bash/Zsh script, `cairn.sh`, plus its tests and a JSON Schema for the manifest. Changes should keep it that way. Please open an issue to discuss before starting work on:

- a new command or option;
- a new remote source (for example, object storage);
- a new write strategy (for example, `append`);
- a new platform (for example, Windows).

These are outside the current scope, and an early conversation saves effort on both sides.

## Set up

You need Docker. The tests run inside a container with no network access, so you do not need the other tools on your host.

```sh
docker compose -f test/compose.yaml run --build --rm test
```

The command runs syntax checks, `shellcheck`, and the full test suite under both Bash and Zsh. A passing run ends with `通过 N，失败 0` for each shell and exits with status 0.

For details on the test layout, single-shell runs, and manual experiments, see [test/README.md](test/README.md).

## Workflow

1. **Read the relevant part of the spec first.** The design lives in `.scratch/cairn/spec.md`, and the implementation tickets are in `.scratch/cairn/issues/`.
2. **Write a failing test first.** Tests go through the command line (`cairn.sh pull` and friends) against the fake Gist server. Do not assert on internal functions. Test business behaviour, such as what is written, where, the merge result, backups, exit codes, and validation that stops a run before writing. Do not add tests that only check the wording, layout, or alignment of output.
3. **Make the test pass with the smallest change.** Then refactor with the tests still green.
4. **Run the full suite in the container.** A change is not ready until both shells pass.
5. **Keep the diff focused.** One logical change per commit.

## Code conventions

- **Bash 3.2 compatibility.** macOS ships Bash 3.2. Do not use associative arrays, `mapfile`, `${var,,}`, `local -n`, or `readlink -f`.
- **Zsh compatibility.** The script also runs under Zsh. Avoid variable names that Zsh treats specially, such as `path`, which is tied to `PATH`.
- **`shellcheck` clean.** Run `shellcheck --shell=bash cairn.sh test/cairn/tests.sh`. Do not silence a warning without a comment that explains why.
- **Errors go to standard error and exit non-zero.** A failed entry is reported in the summary; it does not stop the other entries.
- **No secrets in arguments.** The token is read only from `CAIRN_GITHUB_TOKEN`. Do not add a command-line option for it.
- **Bilingual output.** Every user-facing message goes through `msg '<zh-CN format>' '<en format>' args...`, with both languages side by side. Reuse an existing template where one fits.
- **Comments explain why.** Write Chinese comments in the same style as the existing code.

## Commit messages

Match the style of `git log`: a short type prefix such as `feat:`, `fix:`, `docs:`, or `test:`, then a one-line summary. The body explains the reason for the change when the reason is not obvious from the diff.

## Pull requests

Before you open a pull request, check that:

- [ ] the full suite passes under Docker, for both shells;
- [ ] `shellcheck` reports nothing new;
- [ ] new behaviour has a test that failed before the change;
- [ ] documentation that describes the changed behaviour is updated, including `README.md`, `README.zh-CN.md`, and `CHANGELOG.md` where relevant;
- [ ] the change does not add a runtime dependency without a note in the README.

Describe what changed and why. Mention anything a reviewer should look at closely, such as a decision you made that the spec does not cover.

## Licensing of contributions

The project is licensed under the MIT License (see [LICENSE](LICENSE)). By contributing, you agree that your contributions are licensed under the same terms. Do not submit code you do not have the right to contribute.
