# Support

## Where to start

- [README.md](README.md) (or [README.zh-CN.md](README.zh-CN.md)) explains what Cairn does, how to configure it, and what each command does.
- [test/README.md](test/README.md) explains how to run the tests and how to try the script against a fake Gist server.
- The manifest JSON Schema, [cairn-manifest.schema.json](cairn-manifest.schema.json), describes every field a manifest entry accepts.

## Asking questions and reporting problems

Open an issue on the project's issue tracker: **https://github.com/xianghongai/cairn/issues**.

When you report a problem, include:

- the operating system and version, and the shell (Bash or Zsh, with its version);
- the command you ran, with secrets removed (for example, `CAIRN_GITHUB_TOKEN=<redacted>`);
- the full output, including any `cairn:` error lines and the final summary;
- the output of `cairn.sh --help`, if you are not sure which option applies.

Do not include your GitHub token, a Gist's private contents, or any file that contains credentials.

## Security issues

Do not open a public issue for a security problem. Follow [SECURITY.md](SECURITY.md).

## Response expectations

The project is maintained on a best-effort basis. There is no guaranteed response time.
