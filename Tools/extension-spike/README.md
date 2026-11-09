# 拡張機能の検証（YouTube 字幕翻訳のフェーズ 0）

YouTube の字幕を Safari と Chrome の拡張機能で取り出し、Plamonic 本体へ渡せるかを確かめるための使い捨てのプロジェクト。
本体のコードには入れていない。

```
Extension/        Safari と Chrome で共通の拡張機能（MV3）。Chrome はこのフォルダをそのまま読み込む
Host/             拡張機能を同梱するアプリ。Plamonic が起動していないときだけ、代わりにソケットで待ち受けてダミーの訳を返す
SafariExtension/  Safari Web Extension（.appex、サンドボックス）。sendNativeMessage をソケットへ中継する
NativeHost/       Chrome の Native Messaging ホスト（.app の Contents/MacOS に入る）。stdin/stdout をソケットへ中継する
Shared/           Unix ソケットの読み書き
```

`./build.sh` で Developer ID 署名してビルドし、`~/Applications/PlamonicSpike.app` に置いて起動する。
起動すると `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.smdr.plamonic.spike.json` を書く。

## 結果（2026-11-09、macOS 27.0.1、Safari 27.0.1、Chrome 152）

| 確かめたこと | 結果 |
| --- | --- |
| 字幕の取得（Chrome） | ○ プレーヤーの timedtext 通信（`pot=` 付き）を XHR のフックで拾える |
| 字幕の取得（Safari） | ○ 同じ方法で拾える |
| 別トラックの取得 | ○ 拾った URL の `lang` / `kind=asr` を変えると、同じ動画の別トラックが取れる |
| `pot` の使い回し | 同じ動画の中だけ。別の動画にすると 404。`pot` を外すと空の 200 |
| Safari 拡張 → 本体 | ○ サンドボックスの .appex から App Group のソケットへ接続できる（往復 7 ms） |
| Chrome → 本体 | ○ Chrome が起動したホストからソケットへ接続できる（往復 11〜21 ms）。ホストに App Group の entitlement は不要だった |
| 本物の Plamonic まで（フェーズ 1 後） | ○ Chrome（初回 1,186 ms、キャッシュ 14 ms）、Safari（154 ms、キャッシュ）とも、App Group `NBDP5VK335.io.smdr.Plamonic` の `bridge.sock` 経由で本物の訳が返る |
| 本体がサンドボックスなし | ○ Plamonic と同じ構成でも Safari 拡張は使える |
| 共通コード | ○ 1 つの `Extension/` を両方で使える。違いは `browser ?? chrome` だけ |
| Developer ID 署名だけで Safari に出るか | × Gatekeeper の判定が `Unnotarized Developer ID` で、「未署名の機能拡張を許可」なしでは一覧に出ない。公証後の確認は未実施 |

## 本番で気をつけること

- **Safari は manifest の `"world": "MAIN"` に対応していない**（`safari-web-extension-converter` が警告する）。
  コンテンツスクリプトから `<script src="(拡張機能の URL)/page-hook.js">` を差し込み、`web_accessible_resources` に載せる。
  これは Chrome でも動くので、共通コードのままでよい。
  Safari では `<script src>` の起動通知が 1.5 秒以内に届かないことがあった。`scripting.executeScript` の
  `world: "MAIN"` は Safari でも動いた（manifest の `world` は使えないが、API の `world` は使える）。本番は両方を用意する。
- 読み込み直後の 1 回目の timedtext 通信は `pot` が付かず空になることがある。CC を切り替え直すと付く。
  プレーヤーは字幕を表示しているときしか通信しないので、拡張機能が CC をオンにし、YouTube 自身の字幕は CSS で隠す。
- 自動生成字幕（ASR）の json3 はブラウザで形が違った。Chrome は単語ごとの `segs`（`tOffsetMs` 付き、670 件）、
  Safari は行ごと（172 件）。読み取りは両方に対応させる。
- Safari は隠しフォルダ（例: このワークツリーの `.claude/`）の中にあるアプリの拡張機能を一覧に出さない。
  開発中も `~/Applications` などに置いて起動する。
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` にしないと、Release でも .appex に `get-task-allow` が付き、公証に通らない。
- macOS 15 以降は、グループ外のプロセスから App Group のフォルダを一覧できない（Operation not permitted）。
  一方で、中のソケットへの接続は通った。App Group ID は Team ID を頭に付ける（`NBDP5VK335.…`）。
- 2 回目以降に CC を切り替える処理は、タイマーの中で「もう取れたか」を確かめ直すこと（検証版では取れた後にも 1 回切り替えている）。
