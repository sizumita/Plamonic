# Development

This guide covers building Plamonic from source, running its tests, and how releases and updates are made. The
[README](../README.en.md) has the overview, and [DESIGN.md](DESIGN.md) (Japanese) explains how the app works.

## Requirements

- A Mac with Apple silicon and macOS 15 or later. MLX runs on Apple silicon only.
- Xcode 27 (the Swift 6.4 compiler; the sources use the Swift 5 language mode), with its Metal toolchain, which MLX
  needs for its shaders. If a build says the toolchain is missing, install it with
  `xcodebuild -downloadComponent MetalToolchain`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 (for example `brew install xcodegen`). CI checks that the
  committed project is what this version makes.

## Local setup

```sh
xcodegen generate
xcodebuild -project Plamonic.xcodeproj -scheme Plamonic -configuration Debug \
  -derivedDataPath build/DD -destination 'platform=macOS,arch=arm64' build
open build/DD/Build/Products/Debug/Plamonic.app
```

`project.yml` and the source folders define the project. `xcodegen generate` writes `Plamonic.xcodeproj`, and also
`Plamonic/Resources/Info.plist` and `Plamonic/Resources/Plamonic.entitlements`, so change those in `project.yml`. Run it
again after you add, remove or rename a file, and commit the result. To work in Xcode, open `Plamonic.xcodeproj` and
run the scheme Plamonic.

A build from source has the bundle ID of the release (`io.smdr.Plamonic`) and uses the same settings and models in
`~/Library/Application Support/Plamonic`. Quit an installed Plamonic before you run one. Its version comes from
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, and it has no update key, so it never updates
itself ([Updates](#updates)).

### Signing local builds

`Config/Signing.xcconfig` signs ad hoc, so the project builds on any Mac. An ad-hoc signature changes with every build,
and macOS then forgets the Accessibility permission. With a development certificate, create
`Config/Signing.local.xcconfig` (Git ignores it) to sign with that certificate instead:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = <certificate name or SHA-1>
DEVELOPMENT_TEAM = <team ID>
```

If the permission is lost anyway, remove Plamonic from System Settings › Privacy & Security › Accessibility and add
it again.

A build signed with a team's certificate (`DEVELOPMENT_TEAM`) gets the hardened runtime. An ad-hoc build does not,
because with it macOS would not load the ad-hoc-signed `Sparkle.framework` into the app. Releases get the hardened
runtime from `scripts/sign-app.sh`.

## Tests

```sh
# The app's unit tests
xcodebuild -project Plamonic.xcodeproj -scheme Plamonic -derivedDataPath build/DD \
  -destination 'platform=macOS,arch=arm64' test

# PlamoKit: the tokenizer, the prompts, and the model's numerics against the Python reference
cd Packages/PlamoKit
xcodebuild -scheme PlamoKit-Package -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../../build/PlamoKitDD test
cd ../..

# The release scripts (version.sh and appcast.sh)
scripts/test.sh
```

- The unit tests run inside Plamonic.app, which then starts nothing of its own: no menu bar item, windows, hotkeys,
  reading of other apps or updater. Tests use fakes for Sparkle and never reach the network.
- PlamoKit's model tests use the models installed in `~/Library/Application Support/Plamonic/Models` and skip the
  sizes that are not installed. The download test runs only when `PLAMO_TEST_NETWORK` is set. xcodebuild passes a
  variable to the tests only with the prefix `TEST_RUNNER_`, which it removes, so run it in `Packages/PlamoKit` with
  `TEST_RUNNER_PLAMO_TEST_NETWORK=1 xcodebuild -scheme PlamoKit-Package -destination 'platform=macOS,arch=arm64' test`.
- PlamoKit is tested with `xcodebuild`, not `swift test`: SwiftPM alone cannot compile MLX's Metal shaders.

[CI](../.github/workflows/ci.yml) runs on every pull request and every push to `main`: actionlint and ShellCheck on the
workflows and scripts, `scripts/test.sh`, a check that `xcodegen generate` leaves nothing to commit, the app's unit
tests and PlamoKit's tests. The macOS jobs run on GitHub's `xcode-27` runner image with the Xcode that `XCODE` names in
the workflows. While that image is a preview, `.github/actionlint.yaml` declares its label; when Xcode 27 is on a
regular image, change `runs-on` in both workflows and delete that file.

## Trying changes without the menu bar

### Smoke test

`--smoke-test <bundle ID> <seconds>` runs the reading and translation loop against one app for a while, without
overlays and without bringing that app forward, and logs what happened: the time of each scan, how many segments had
the original's size and colour, links, burst pauses, measured colours, and pauses for password entry. Text in the log
is masked, and settings it changes apply to a copy. Started from a terminal, Plamonic uses that terminal's Accessibility
permission.

```sh
plamonic=build/DD/Build/Products/Debug/Plamonic.app/Contents/MacOS/Plamonic
"$plamonic" --smoke-test com.hnc.Discord 30
"$plamonic" --smoke-test com.hnc.Discord 30 --target en          # an app in Japanese: translate into English
"$plamonic" --smoke-test com.apple.Terminal 30 --show-overlays   # draw the translations; the app stays behind
"$plamonic" --smoke-test com.apple.Terminal 40 --final 2b --progressive on --burst-threshold 8
```

| Option | Effect |
| --- | --- |
| `--pid <pid>` | One process of the app, such as a copy started for the test |
| `--use-preset` | Ignores the app's saved profile and uses its built-in preset |
| `--target <language>`, `--final <size>`, `--progressive on\|off`, `--burst-threshold <n>` | The target language, the model, progressive translation and the burst pause, for this run only |
| `--password-guard <seconds>` | Checks for password entry at this interval (default 0.25, 0.05–5) and logs every change of what it sees (app names only) |
| `--show-overlays` | Draws the translations, and logs the links mapped into them and the click areas |

With `--show-overlays`, these act on the first link drawn in a translation, in this order, and `--hover-at` after them:

| Option | Effect |
| --- | --- |
| `--hover-first-link` | Shows the hover look for `--hover-hold <seconds>` (default 1) without moving the pointer |
| `--context-menu-first-link` | Right-clicks the link, logs the menu that appears and closes it within a second without choosing an item. Exits with status 4 if a menu cannot be closed. Use it with a test window only |
| `--activate-first-link` | Presses the link and logs the result |
| `--dry-run-links` | Logs what the steps above would do, without pressing a link or opening a URL. Always add it when you try links in another app |
| `--hover-at <x>,<y>` | Acts as if the pointer rested at that point (AX coordinates) once its translation is final, then left after `--hover-hold` seconds, and logs what showed the original |

### Tools

- `Tools/build-ax-probe.sh` builds `build/ax-probe`, which prints an app's AX tree (`build/ax-probe <bundle ID>
  --tree`, masked) or what the extraction rules find in it. `--links` adds each paragraph's links. Run it without
  arguments for its options.
- `Tools/overlay-demo/build.sh` builds a demo that draws overlays over made-up windows, or renders them to PNG files
  with `--render <dir>`.
- `plamo-cli` (in `Packages/PlamoKit`) tokenizes and translates text, benchmarks a model, and downloads, verifies and
  lists models from the command line.
- `--update-probe` checks for an update without the menu bar ([Trying an update locally](#trying-an-update-locally)).

Logs go to the unified log under the subsystem `io.smdr.Plamonic` (Console, or
`log stream --predicate 'subsystem == "io.smdr.Plamonic"'`).

## Project layout

```
Plamonic/
├── App/            menu bar, launch and quit, onboarding, smoke test
├── Core/           types shared between the modules (settings, segments, overlay items, service contracts)
├── Accessibility/  AXUIElement wrapper, Electron accessibility, window IDs, AX notifications
├── Extraction/     paragraphs from the AX tree, terminal screens
├── Settings/       storing and recovering settings, app presets, the settings window
├── Overlay/        the transparent panels, layout and colours that match the original, popovers
├── ScreenCapture/  background and text colours from the screen (with Screen Recording permission only)
├── Translation/    cache, language detection, progressive translation and burst pauses, the PlamoKit backend
├── Session/        the live loop: front app, scans, drawing, input
├── Hotkeys/        global hotkeys
└── Updates/        Sparkle: feeds, the update settings, --update-probe
PlamonicTests/      the app's unit tests
Packages/PlamoKit/  runs PLaMo 3 Translate with MLX; plamo-cli
Tools/              ax-probe, overlay demo
scripts/            release scripts (versions, signing, feeds) and their tests
docs/               user guide, design notes, AX notes
```

## Dependencies

- [mlx-swift](https://github.com/ml-explore/mlx-swift) is pinned to one exact version in
  `Packages/PlamoKit/Package.swift`, and [Sparkle](https://github.com/sparkle-project/Sparkle) to one exact version in
  `project.yml`.
- Both `Packages/PlamoKit/Package.resolved` and
  `Plamonic.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` are committed, and CI builds with
  `-onlyUsePackageVersionsFromResolvedFile`. mlx-swift is in both files, so an upgrade changes `Package.swift` and both
  resolved files in one pull request: resolve PlamoKit (`swift package resolve` in `Packages/PlamoKit`) and the app
  (`xcodebuild -resolvePackageDependencies -project Plamonic.xcodeproj -scheme Plamonic`).
- Dependabot proposes upgrades of the actions and of PlamoKit's packages. A pull request that upgrades mlx-swift needs
  the app's `Package.resolved` too. Upgrade Sparkle by hand: change `exactVersion` in `project.yml`, run
  `xcodegen generate`, and resolve the app.
- Keep [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) current: Sparkle's license text belongs to the pinned
  version, and an mlx-swift upgrade can change what it builds into the app (mlx, mlx-c, fmt, json, metal-cpp and
  PocketFFT in `Source/Cmlx`). Add every new dependency there.
- `LICENSES/` holds the PLaMo Community License as the model repositories publish it (`LICENSE/en` and `LICENSE/ja`).
  Replace both files when Preferred Networks changes it.
- Every action in the workflows is pinned to a full commit SHA, with its version in a comment.

## Releases

Every push to `main` that changes the app builds a beta, and a tag `vX.Y.Z` on a commit of `main` builds that release.
[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds both. It can also be run by hand from the
Actions tab, on `main` or on a release tag, to build again.

|                    | Beta                                                         | Release                                                     |
| ------------------ | ------------------------------------------------------------ | ----------------------------------------------------------- |
| Started by         | a push to `main` that changes the app                        | a tag `vX.Y.Z` on a commit of `main`                        |
| Version            | `X.Y.Z-beta.N`                                               | `X.Y.Z`                                                     |
| Published as       | the prerelease `beta`, whose tag moves to the built commit   | the tag's release, which becomes the latest release         |
| Files              | `Plamonic-Beta.dmg`, `Plamonic-Beta.zip`, `appcast.xml`      | `Plamonic.dmg`, `Plamonic.zip`, `appcast.xml`               |
| A file's link      | `https://github.com/sizumita/Plamonic/releases/download/beta/` | `https://github.com/sizumita/Plamonic/releases/latest/download/` |
| Signing secrets in | the environment `beta`                                       | the environment `production`                                |

Betas and releases are the same app, `Plamonic.app` with the bundle ID `io.smdr.Plamonic`, so either replaces the other
and keeps the settings, the models and the permissions. The DMG is for the first install, and the zip is the update
archive that installed apps download.

`scripts/version.sh` gives the versions. A release has its tag's. A beta is a prerelease of the next version: the last
release tag merged into the commit with its patch raised, or `MARKETING_VERSION` in `project.yml` when that is higher
(raise it there before a minor or a major release), and N counts the commits since that tag, or all commits before the
first release. The build number (`CFBundleVersion`) is the number of commits in the build's history for both kinds, so
it grows with every commit; Sparkle compares it to decide what is newer. The script needs the whole history and refuses
a shallow clone.

To release, tag a commit of `main` and push the tag:

```sh
git tag v0.1.0 <commit>
git push origin v0.1.0
```

The workflow then builds, signs and notarizes the app, and publishes the release with notes that GitHub writes from the
pull requests since the previous release. A tag on a commit that is not on `main` fails.

The workflow has four jobs. `version` computes the version. `build` compiles the Release app without any secret,
unsigned, with the version and the public update key. `sign` runs in the environment of its kind, signs and notarizes
the app, makes the update archive and the disk image, verifies them, and writes the feed item. `publish` is the only job
that may write to the repository: it uploads the files first and the feed last, so that a feed never names a file that
is not there yet. A run never takes the beta back: if the published beta already has a newer build, for example when
an older run is re-run, `publish` leaves it as it is. A release adds itself to the beta feed only when that feed lists
no newer release and no beta is being published at that moment.

### Signing the macOS app

Releases and betas are signed with the team's Developer ID and notarized by Apple, so Gatekeeper opens them, and their
signature stays the same from one version to the next, so macOS keeps the Accessibility permission across updates.
`scripts/sign-app.sh` signs from the inside out with the hardened runtime and a secure timestamp: Sparkle's
`Installer.xpc`, `Downloader.xpc`, `Autoupdate` and `Updater.app`, then each framework, then the app with
`Plamonic/Resources/Plamonic.entitlements`. With the identity `-` it signs ad hoc, which is enough to try the script.

The `sign` job imports the certificate into a temporary keychain and takes everything else from the secrets of its
environment. Set them up once:

1. A **Developer ID Application** certificate of the team (NBDP5VK335), which only the team's Account Holder can create
   (Apple Developer › Certificates). Export it with its private key from Keychain Access as a `.p12` file with a
   password. Plamonic uses no capability that needs an App ID or a provisioning profile.
2. An **App Store Connect API key** for notarization (App Store Connect › Users and Access › Integrations, a team key
   with the Developer role). Note its key ID and issuer ID, and download its `.p8` file, which Apple offers only once.
3. The secrets, the same in both environments:

   ```sh
   for env in beta production; do
     base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE --env "$env"
     gh secret set APPLE_CERTIFICATE_PASSWORD --env "$env"
     gh secret set APPLE_SIGNING_IDENTITY --env "$env"   # Developer ID Application: <name> (NBDP5VK335)
     gh secret set APPLE_API_KEY --env "$env"            # the key ID
     gh secret set APPLE_API_ISSUER --env "$env"         # the issuer ID
     gh secret set APPLE_API_PRIVATE_KEY --env "$env" < AuthKey_<key ID>.p8
   done
   ```

A missing secret stops the job with an error that points here.

### Updates

The published app updates itself with [Sparkle](https://sparkle-project.org) (`Plamonic/Updates`). It reads one of two
feeds, which the release workflow publishes:

| Feed   | URL                                                                         | Items                                  |
| ------ | --------------------------------------------------------------------------- | -------------------------------------- |
| stable | `https://github.com/sizumita/Plamonic/releases/latest/download/appcast.xml` | the latest release                     |
| beta   | `https://github.com/sizumita/Plamonic/releases/download/beta/appcast.xml`   | the newest beta and the latest release |

The app reads the beta feed when ベータ版を受け取る is on, and the stable feed otherwise. The setting
(`receiveBetaUpdates` in `settings.json`) starts unset and then follows the build: a beta build turns it on and stores
that the first time it runs. Sparkle installs an item only when its build number is higher than the running app's, so
a beta user also gets a newer release, and turning betas off never goes back to an older release. A release also
rewrites the beta feed, which keeps its beta and gets the new release. Changing ベータ版を受け取る while automatic
checks are on restarts Sparkle's schedule, so the new feed is checked in the background a few seconds later; with them
off, the next 今すぐ確認 reads it.

Plamonic checks once a day (`SUScheduledCheckInterval`) without asking first (`SUEnableAutomaticChecks`). A scheduled
check never opens a window: Plamonic shows the update in its menu (Sparkle's gentle reminders), and Sparkle's window
appears when the user chooses that line, アップデートを確認… or 今すぐ確認.

Sparkle installs an update only if its archive's EdDSA signature verifies under the public key in the app
(`SUPublicEDKey`, from the build setting `PLAMONIC_SPARKLE_PUBLIC_KEY`). That setting is empty in `project.yml`, and a
build without the key never starts the updater: builds from source and CI's test builds never update themselves. The
release workflow takes the public key from the repository variable `SPARKLE_PUBLIC_KEY` and the private key from the
secret `SPARKLE_PRIVATE_KEY`. Betas and releases are one app with one key, so both environments hold the same private
key. Make the key once with Sparkle's `generate_keys`, from the Sparkle release that the project pins:

```sh
bin="$(scripts/sparkle-tools.sh /tmp/sparkle-tools)"
"$bin/generate_keys" --account plamonic       # makes the key in your login keychain and prints the public key
"$bin/generate_keys" --account plamonic -x sparkle-private-key
gh variable set SPARKLE_PUBLIC_KEY --body "$("$bin/generate_keys" --account plamonic -p)"
for env in beta production; do
  gh secret set SPARKLE_PRIVATE_KEY --env "$env" < sparkle-private-key
done
rm sparkle-private-key
```

The build fails when the variable is not a public key, and the `sign` job fails when the secret is not its private
half. Keep the key in your keychain and a copy somewhere safe outside GitHub, which never shows a secret again: the
installed apps accept only updates signed with it. If the key is lost or has to change, put the new public and private
keys in place and publish a release signed with the same Developer ID certificate as before: Sparkle accepts a new key
in an update whose code signature is unchanged, and a new certificate in an update whose key is unchanged, but never
both in one update.

### Trying an update locally

`--update-probe <feed URL | stable | beta> [--timeout <seconds>]` runs one update check without the menu bar app. It
downloads the update it finds, lets Sparkle verify it up to the point of installing, then cancels the installation and
exits, without windows, permission prompts or translation. It exits with 0 when it found and verified an update, 1 when
there is none, 2 on an updater error (feed, download, signature), 3 when it cannot start (for example, a build without
the key), and 4 on a timeout.

Sparkle keeps its state per bundle ID and requires an update to have the bundle ID of the app it updates, so try
updates with a copy that has a bundle ID of its own:

```sh
# A throwaway Ed25519 key: the private key in build/test-key, the public key in $public_key.
mkdir -p build
public_key="$(xcrun swift - <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(toFile: "build/test-key", atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
)"

bin="$(scripts/sparkle-tools.sh /tmp/sparkle-tools)"
for build in 100 101; do
  xcodebuild -project Plamonic.xcodeproj -scheme Plamonic -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/UpdateTest ARCHS=arm64 \
    PRODUCT_BUNDLE_IDENTIFIER=io.smdr.Plamonic.updatetest PLAMONIC_SPARKLE_PUBLIC_KEY="$public_key" \
    MARKETING_VERSION="0.1.$((build - 100))" CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO build
  mkdir -p "build/updatetest/$build"
  ditto build/UpdateTest/Build/Products/Release/Plamonic.app "build/updatetest/$build/Plamonic.app"
  scripts/sign-app.sh "build/updatetest/$build/Plamonic.app" - Plamonic/Resources/Plamonic.entitlements
done

mkdir -p build/feed
ditto -c -k --sequesterRsrc --keepParent build/updatetest/101/Plamonic.app build/feed/Plamonic.zip
signature="$("$bin/sign_update" --ed-key-file build/test-key -p build/feed/Plamonic.zip)"
scripts/appcast.sh item --version 0.1.1 --build 101 --url http://127.0.0.1:8000/Plamonic.zip \
  --length "$(stat -f %z build/feed/Plamonic.zip)" --signature "$signature" --minimum-system 15.0 >build/item.xml
scripts/appcast.sh feed "Plamonic test" build/item.xml >build/feed/appcast.xml
python3 -m http.server 8000 --bind 127.0.0.1 --directory build/feed &

build/updatetest/100/Plamonic.app/Contents/MacOS/Plamonic --update-probe http://127.0.0.1:8000/appcast.xml
```

Afterwards, stop the server and remove Sparkle's state for the test copy: `~/Library/Caches/io.smdr.Plamonic.updatetest`
and the defaults domain `io.smdr.Plamonic.updatetest`.

## Setting up the GitHub repository

The release workflow runs on the first push to `main`, so create the repository without pushing and set it up first.
It has to be public: the installed apps read their feeds and updates from its releases without signing in, and the
READMEs link to them.

```sh
gh repo create sizumita/Plamonic --public
```

1. Environments (Settings › Environments): `beta`, limited to the branch `main`, and `production`, limited to tags
   `v*` (a required reviewer is optional). Give both the secrets of
   [Signing the macOS app](#signing-the-macos-app) and `SPARKLE_PRIVATE_KEY`.
2. The repository variable `SPARKLE_PUBLIC_KEY` ([Updates](#updates)).
3. In the repository's security settings, turn on private vulnerability reporting, which
   [SECURITY.md](../SECURITY.md) relies on, and Dependabot alerts.

Then push:

```sh
git remote add origin https://github.com/sizumita/Plamonic.git
git push -u origin main
```

The workflows ask for the permissions they need themselves, so the default read-only token is enough. Until the first
release exists, the stable feed is missing: a scheduled check on it fails quietly, and a check the user starts shows
Sparkle's error.
