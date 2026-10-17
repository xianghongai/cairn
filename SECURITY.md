# Security Policy

## Reporting a vulnerability

Report security issues privately. Do not open a public issue, pull request, or discussion for them.

Send a report to **https://github.com/xianghongai/cairn/security/advisories/new**. Include:

- a description of the problem and the impact you expect;
- steps to reproduce it, or a minimal manifest or command that triggers it;
- the version or commit you tested, and the shell and operating system.

The maintainers will acknowledge a report, investigate it, and keep you informed of progress. Credit is given in the changelog unless you ask to remain anonymous.

## Scope

In scope:

- `cairn.sh` and the code it runs, including the write, backup, and merge paths;
- the handling of the GitHub token and of the files fetched from the Gist;
- the install step and the distribution instructions in the README.

Out of scope:

- the security of GitHub itself, of the Gist service, or of the tools Cairn calls (`jq`, `yq`, `tomlkit`, `jsonc-parser`, `curl`);
- problems that require the attacker to already control the user's account or machine.

## Handling your token

Cairn reads the GitHub token only from `CAIRN_GITHUB_TOKEN`. To keep the token safe:

- create a token that can read only the Gist it needs, and set an expiry;
- avoid writing the token into shell history, dotfiles, or a manifest;
- rotate the token if you suspect it has leaked.

Cairn never writes the token to disk and never passes it on the command line.
