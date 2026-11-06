# Plamonic

[English](README.md) | 日本語

Plamonic は、ほかのアプリに表示されている文章をその場で翻訳し、原文の上に訳文を重ねて表示する macOS のメニューバー常駐アプリです。
訳文は原文と同じ文字の大きさ・行間・色で描くので、アプリがはじめから訳文の言語で書かれているように読めます。
クリックはそのままアプリに届き、訳文の中のリンクも押せます。⌥ を押している間は原文が見えます。

翻訳には Preferred Networks の PLaMo 3 Translate を使い、Mac の中で動かします。画面の表示は日本語です。

## プライバシー

- 画面の文章は macOS のアクセシビリティ API で読み取ります。スクリーンショットや OCR は使いません。
- モデルは [MLX Swift](https://github.com/ml-explore/mlx-swift) で Mac の中で動かすので、文章が外に送られることはありません。
  通信するのは、Hugging Face からモデルをダウンロードするときと、GitHub でアップデートを確認するときだけです。
- 画面収録の許可は任意です。許可すると、訳文を原文になじませるために文章のまわりの色を測ります。取り込んだ画面は色を測るためだけにメモリの中で使い、保存も送信もしません。
- パスワードを入力している間（パスワード欄、システムのパスワード画面）は、ほかのアプリの文章も画面も読み取りません。パスワード欄の中身は、いつでも読み取りません。
- 訳文のキャッシュは `~/Library/Application Support/Plamonic` に、自分だけが読める権限で保存します。保存しないようにもできます。

## 動作環境

- macOS 15 以降、Apple シリコン（M1 以降）の Mac
- メモリ: 0.8B / 2B モデルは 8 GB 以上、8B は 16 GB 以上、31B は 48 GB 以上
- ディスク: 既定のモデル（2B と、下書き用の 0.8B）で約 3.4 GB

## ダウンロード

1. [最新のリリース](https://github.com/sizumita/Plamonic/releases/latest)から `Plamonic.dmg` をダウンロードして開き、Plamonic を「アプリケーション」フォルダにドラッグします。
   配布しているアプリは Developer ID で署名し、Apple の公証を受けているので、ふつうのアプリと同じように開けます。
2. Plamonic を開きます。アイコンは Dock ではなくメニューバーに出ます。
3. 案内に従って、「システム設定」>「プライバシーとセキュリティ」>「アクセシビリティ」で Plamonic をオンにします。再起動は要りません。
4. 同じウインドウからモデルをダウンロードします。ダウンロードが終わると翻訳が始まります。モデルは Preferred Networks が [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license) のもとで公開しています。使う前にライセンスを確認してください。商用で利用する場合は Preferred Networks への登録が必要です。

Plamonic は 1 日に 1 回アップデートを確認し、新しい版があればウインドウを出さずにメニューに表示します。
`main` ブランチが変わるたびに作るベータ版も受け取りたいときは、「設定」>「一般」>「アップデート」で「ベータ版を受け取る」をオンにしてください。ベータ版も同じアプリなので、設定とモデルはそのまま使えます。

設定の一つひとつ、対応アプリ、うまく動かないときの確かめ方は[使い方](docs/USAGE.ja.md)にまとめています。

## ソースからビルドする

Xcode 27 と [XcodeGen](https://github.com/yonaskolb/XcodeGen) が必要です。

```sh
git clone https://github.com/sizumita/Plamonic.git
cd Plamonic
xcodegen generate
xcodebuild -project Plamonic.xcodeproj -scheme Plamonic -configuration Debug \
  -derivedDataPath build/DD -destination 'platform=macOS,arch=arm64' build
open build/DD/Build/Products/Debug/Plamonic.app
```

このビルドはアドホック署名なので、ビルドし直すたびに macOS がアクセシビリティの許可を忘れます。
開発用の証明書がある場合は `Config/Signing.local.xcconfig`（Git には含めません）に次のように書くと、許可が保たれます。

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = <証明書の名前または SHA-1>
DEVELOPMENT_TEAM = <チーム ID>
```

ソースからビルドしたアプリは自動でアップデートしません。

## ドキュメント

- [docs/USAGE.ja.md](docs/USAGE.ja.md): 使い方
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): ビルド、テスト、リリースとアップデート（英語）
- [docs/DESIGN.md](docs/DESIGN.md): 設計
- [docs/AX_NOTES.md](docs/AX_NOTES.md): 対応アプリのアクセシビリティの構造

## 開発に参加する

不具合の報告やプルリクエストを歓迎します。[CONTRIBUTING.md](CONTRIBUTING.md) を見てください。
セキュリティの問題は、公開の Issue ではなく [SECURITY.md](SECURITY.md) の方法で知らせてください。

## ライセンス

Copyright (C) 2026 sizumita.

Plamonic は [GNU Affero General Public License v3.0 only](LICENSE)（`AGPL-3.0-only`）のもとで公開しているフリーソフトウェアです。
Plamonic に含まれる、またはビルドに使うサードパーティのコードは、それぞれのライセンスに従います。一覧は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にまとめています。

PlamoKit のうち PLaMo 3 Translate のモデルのリポジトリから移植した部分と、モデルで作ったテストデータには、PLaMo Community License（[日本語](LICENSES/PLaMo-Community-License.ja.txt)、[英語](LICENSES/PLaMo-Community-License.txt)）も適用されます。

PLaMo 3 Translate のモデルは Plamonic には含まれません。Plamonic は Hugging Face からモデルをダウンロードします。モデルは Preferred Networks が PLaMo Community License のもとで公開しています。

Built with PLaMo.
