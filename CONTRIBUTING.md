# Contributing to Plamonic

Plamonic is a personal project, maintained in spare time. Bug reports, fixes and ideas are welcome, in English or
Japanese.

- **Bugs:** open an issue with your macOS version, your Mac, the Plamonic version (設定 › 一般 › アップデート), the app
  you were translating, and the steps to reproduce. Logs and screenshots can contain text from other apps, so check them
  before you attach them.
- **Security problems:** do not open a public issue; see [SECURITY.md](SECURITY.md).
- **Larger changes:** open an issue first, so that we can agree on the approach before you write the code.

## Pull requests

- Build and test as [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) describes. The app's unit tests must pass, and
  PlamoKit's tests too when you change `Packages/PlamoKit`.
- After you change `project.yml` or add, remove or rename a file, run `xcodegen generate` and commit the project.
- Add tests for new logic. Tests use fakes, never the network or other apps.
- Plamonic reads other apps' text. Do not log it or keep it anywhere a feature does not need it; logs name apps and
  count things, and the smoke test masks text.
- Code comments are in English, short and plain. The app's interface is in Japanese, in the plain, short style of the
  existing text.
- Keep each commit focused, and say in its message why the change is needed.

## License

By contributing, you agree that your contributions are licensed under the
[GNU Affero General Public License v3.0 only](LICENSE), the license of this project.
