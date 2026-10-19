# Contributing to Hubbub

Thanks for helping. Hubbub is community driven: the current focus is a foundation that works well and consistently everywhere, and after that the features people ask for.

## Ways to help

- **Testing and bug reports.** Run Hubbub with friends on different networks, machines and platforms. When something breaks, open an issue with what you did, what you expected, what happened, your OS, and logs if you can get them. On Linux, run `journalctl --user -u hubbub` if you run it as a service, or start it from a terminal. On Windows, start `hubbub.exe` from a terminal with its output redirected to a file.
- **Feature ideas.** Open an issue that describes the problem you want solved, not only the solution. Add a 👍 to existing ideas you want too.
- **Code and docs.** Pull requests are welcome. For anything larger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Building

See [Build from source](README.md#build-from-source) in the README. In short: Flutter for the app in `app/`, stable Rust for the core in `core/`, and `tools/fetch-livekit.sh` for the bundled media server.

## Before you send a pull request

- **App:** run `flutter analyze` and `flutter test` in `app/`. Both must be clean.
- **Core:** run `cargo test -p hubbub-core --features test-util`.
- **Tests:** add or update tests for what you changed. A bug fix should come with a test that fails without it.
- **Wire compatibility:** if you change a wire message, read the compatibility rule above `CtlMsg` in `core/src/proto.rs`. People update at different times, so different builds must keep talking to each other.
- **Line endings:** keep each file's existing line endings, and keep the change focused. Unrelated reformatting makes a review hard.
- **No secrets:** never commit keys, passwords or personal data. Use placeholders such as `<API_KEY>` in docs and examples.

## Licence

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
