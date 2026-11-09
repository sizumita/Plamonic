# ブラウザ拡張機能の検証メモ

ブラウザ拡張機能（[BrowserExtension/](../BrowserExtension/)、[DESIGN.md](DESIGN.md) 9 章）を作る前と作る途中に、実際のブラウザで
確かめたこと。最初の検証は使い捨てのプロジェクト（Safari 拡張と Chrome の Native Messaging ホストを持つアプリ）で行い、
その中身が Plamonic に入ったあとで消した。

## 最初の検証（2026-11-09、macOS 27.0.1、Safari 27.0.1、Chrome 152）

| 確かめたこと | 結果 |
| --- | --- |
| 字幕の取得（Chrome） | ○ プレーヤーの timedtext 通信（`pot=` 付き）を XHR のフックで拾える |
| 字幕の取得（Safari） | ○ 同じ方法で拾える |
| 別トラックの取得 | ○ 拾った URL の `lang` / `kind=asr` を変えると、同じ動画の別トラックが取れる |
| `pot` の使い回し | 同じ動画の中だけ。別の動画にすると 404。`pot` を外すと空の 200 |
| Safari 拡張 → 本体 | ○ サンドボックスの .appex から App Group のソケットへ接続できる（往復 7 ms） |
| Chrome → 本体 | ○ Chrome が起動したホストからソケットへ接続できる（往復 11〜21 ms）。ホストに App Group の entitlement は要らない |
| 本物の Plamonic まで | ○ Chrome（初回 1,186 ms、キャッシュ 14 ms）、Safari（154 ms、キャッシュ）とも、App Group の `bridge.sock` 経由で訳が返る |
| 本体がサンドボックスなし | ○ Plamonic と同じ構成でも Safari 拡張は使える |
| 共通コード | ○ 1 つのコードを両方で使える。違いは `browser ?? chrome` と、サイドバーの出し方だけ |
| Developer ID 署名だけで Safari に出るか | × Gatekeeper の判定が `Unnotarized Developer ID` で、「未署名の機能拡張を許可」なしでは一覧に出ない。公証したベータ版で確かめること |

## 気をつけること

### Safari

- manifest の `"world": "MAIN"` に対応していない（`safari-web-extension-converter` が警告する）。コンテンツスクリプトから
  `<script src="(拡張機能の URL)/page-hook.js">` を差し込み、`web_accessible_resources` に載せる。起動通知が 1.5 秒以内に
  届かないことがあるので、`scripting.executeScript` の `world: "MAIN"`（API の `world` は使える）も用意する。
- 拡張機能のページを iframe でサイトのページに入れると、ページが落ちた（「このWebページで問題が起きた」）。サイドバーは
  同じ画面部品をページの shadow root の中で直接動かす。
- 隠しフォルダ（ワークツリーの `.claude/` など）の中にあるアプリの拡張機能を一覧に出さない。開発中も `~/Applications`
  などに置いて起動する。
- 自動生成字幕（ASR）の json3 が行ごと（Chrome は単語ごと）。読み取りは両方に対応させる。
- サンドボックスの .appex は App Group のコンテナにしか届かない。App Group ID は Team ID を頭に付ける（`NBDP5VK335.…`）。
  macOS 15 以降、グループ外のプロセスはそのフォルダを一覧できないが、中のソケットへの接続は通る。
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` にしないと、Release でも .appex に `get-task-allow` が付き、公証に通らない。

### Chrome

- `<script src="chrome-extension://…">` をサイトに差し込むと「Unsafe attempt to load URL」になる。Chrome には manifest の
  `"world": "MAIN"` のコンテンツスクリプトで読み込む。
- `sidePanel.setPanelBehavior({ openPanelOnActionClick })` は拡張機能を更新しても残る。やめるときは明示的に `false` にする。
- サイドパネルは `sidePanel.setOptions({ tabId, path })` でタブごとに出せる。`sidePanel.open()` はクリックの中で、何かを
  await する前に呼ぶ。

### YouTube

- 読み込み直後の 1 回目の timedtext 通信は `pot` が付かず空になることがある。CC を切り替え直すと付く。プレーヤーは
  字幕を表示しているときしか字幕を取りに行かない。
- コメントは `#content-text`（`yt-attributed-string`、行の中に表示される）。@メンションのリンクが先頭にあっても 1 段落。
- 返信を開いたときなどに、コメントの要素を使い回して別のコメントを入れる。自分が書き換えた変化だけを無視し（`takeRecords`）、
  文章が変わった段落は訳し直す。

### Reddit

- フィードの投稿はカード全体に透明なリンクがかぶさり、本文は `pointer-events: none`。ポインタの下の要素も当たり判定も
  本文に届かないので、訳した段落の箱とポインタの位置で探す。
- IntersectionObserver がコメントの段落の多くを取りこぼした。画面に見えている段落は箱の位置で測る。
- 私たちの自動テストのブラウザからは開けない（安全上の制限）。確かめるときは利用者のブラウザで。
