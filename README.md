# Plamonic

English | [日本語](README.ja.md)

Plamonic is a macOS menu bar app that translates other apps in place. It reads the text an app shows and draws the
translation over the original, in the original's size, line spacing and colour, so the app reads as if it were written
in your language. Clicks still go to the app, links in a translation work, and holding ⌥ shows the original.

Translation runs on your Mac with Preferred Networks' PLaMo 3 Translate models. The app's interface is in Japanese.

## Privacy

- Plamonic reads text through the macOS Accessibility API, not from screenshots or OCR.
- The models run on your Mac with [MLX Swift](https://github.com/ml-explore/mlx-swift), so text never leaves it.
  Plamonic uses the network only to download the models from Hugging Face and to check GitHub for updates.
- Screen Recording permission is optional. With it, Plamonic measures the colours around the text so the translation
  blends in. The captured pixels are used for that alone, in memory, and are never saved or sent.
- While you type a password (in a password field or a system password dialog), Plamonic reads nothing from other apps
  and does not capture the screen. It never reads what is in a password field.
- Translations are cached in `~/Library/Application Support/Plamonic`, readable only by your account. The cache can be
  turned off.

## Requirements

- macOS 15 or later, on Apple silicon (M1 or later).
- Memory: 8 GB for the 0.8B and 2B models, 16 GB for 8B, 48 GB for 31B.
- Disk: about 3.4 GB for the default models (2B, with 0.8B for quick drafts).

## Download

1. Download `Plamonic.dmg` from the [latest release](https://github.com/sizumita/Plamonic/releases/latest), open it
   and drag Plamonic to Applications. Releases are signed with a Developer ID and notarized by Apple, so they open
   like any other app.
2. Open Plamonic. Its icon appears in the menu bar, not in the Dock.
3. When it asks, allow Plamonic in System Settings › Privacy & Security › Accessibility. You do not need to restart it.
4. Download the models from the same window. Translation starts once the download finishes. Preferred Networks
   publishes the models under the
   [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-en); read it before you use
   them. Commercial use requires registration with Preferred Networks.

Plamonic checks for updates once a day and shows a new version in its menu, without opening a window. To also get the
beta versions built from every change to `main`, turn on ベータ版を受け取る (receive beta versions) in 設定 › 一般 ›
アップデート. A beta is the same app and keeps your settings and models.

The [user guide](docs/USAGE.ja.md) (Japanese) explains every setting, the supported apps and what to do when
something does not work.

## Build from source

You need Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/sizumita/Plamonic.git
cd Plamonic
xcodegen generate
xcodebuild -project Plamonic.xcodeproj -scheme Plamonic -configuration Debug \
  -derivedDataPath build/DD -destination 'platform=macOS,arch=arm64' build
open build/DD/Build/Products/Debug/Plamonic.app
```

The build is signed ad hoc, so macOS forgets its Accessibility permission each time you build again. If you have a
development certificate, name it in `Config/Signing.local.xcconfig`, which is not committed, and the permission stays:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = <certificate name or SHA-1>
DEVELOPMENT_TEAM = <team ID>
```

A build from source does not update itself.

## Documentation

- [docs/USAGE.ja.md](docs/USAGE.ja.md): the user guide (Japanese)
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): building, tests, releases and updates
- [docs/DESIGN.md](docs/DESIGN.md): how Plamonic works (Japanese)
- [docs/AX_NOTES.md](docs/AX_NOTES.md): the accessibility structure of the supported apps (Japanese)

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems
privately, as described in [SECURITY.md](SECURITY.md).

## License

Copyright (C) 2026 sizumita.

Plamonic is free software, licensed under the [GNU Affero General Public License v3.0 only](LICENSE)
(`AGPL-3.0-only`). The third-party code it contains or is built with keeps its own license:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists it.

The parts of PlamoKit that are ported from the PLaMo 3 Translate model repositories, and the test data generated with
the models, are also subject to the PLaMo Community License ([English](LICENSES/PLaMo-Community-License.txt),
[Japanese](LICENSES/PLaMo-Community-License.ja.txt)).

The PLaMo 3 Translate models are not part of Plamonic and are not included in it. Plamonic downloads them from Hugging
Face, and they are licensed by Preferred Networks under the PLaMo Community License.

Built with PLaMo.
