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

## 投稿の翻訳ボタンのために確かめたこと（2026-11-10、Chrome 152、表示言語は日本語）

### X（x.com、pro.x.com）

- ログインしているときの画面は従来の構造（`article[data-testid="tweet"]`、本文は `[data-testid="tweetText"]`）。
  本文の `lang` に投稿の言語が入る（`en`、`ja` など。メディアだけ・メンションだけの投稿は `qme`、`qam` などの独自の値、
  不明は `und`）。pro.x.com も同じ構造。
- X が Grok で自動的に訳した投稿は、本文の直前に行が付く（`div[dir="ltr"]`、先頭の子が Grok のアイコンの `svg`）。
  - 訳を表示中: `svg`、`span`（「英語からの翻訳」）、`button`（「原文を表示」）、`button`（「自動翻訳について」、アイコンだけ）。
    本文の `lang` は表示言語（`ja`）。
  - 原文を表示中: `svg`、`button`（「翻訳を表示」）、`button`（「自動翻訳について」）。本文の `lang` は投稿の言語。
  - 文言は表示言語で変わるので、形で見分ける（文字のある `span` があれば訳を表示中、文字のある `button` が切り替え）。
  - 本文の要素は同じもののまま、中身と `lang` だけが変わる。切り替えのたびに行の `button` は作り直され、行の末尾に付く
    （私たちが行に足したボタンは、そのままだと X のボタンより前に来る）。
  - 切り替えボタンは `click()` で動く（原文は手元にあり、通信は起きない）。
- 引用された投稿（`[role="link"]` の中）は、訳と「英語からの翻訳」だけが出て、切り替えボタンがない。原文は DOM にない。
- 自動で訳されない外国語の投稿（返信など）には、行そのものがない。
- pro.x.com では、本文の直前の `div[dir="ltr"]` が名前と時刻の行のこともある（通知の列）。先頭の子が `svg` かどうかで分ける。
- 本文の要素の直後に兄弟の要素を足し、本文に属性を足しても、切り替え（React の描き直し）は壊れない。本文の子を差し替えるのは
  避ける（本文の子の数が訳と原文で違うので、描き直しで React が自分の子を取り除けなくなる）。
- CSP の `style-src` は `'unsafe-inline'` を含むので、`<style>` を足せる。
- ログインしていないときの画面は別の新しい構造（`data-testid` がなく、`article` の中の `div[dir="auto"]` が本文、
  その上に Grok のアイコンと「翻訳を表示」）。「翻訳を表示」はログインを求める。こちらには対応していない。

### YouTube のコメント

- 外国語のコメントには `#main` の中、本文（`ytd-expander`）の下に `ytd-tri-state-button-view-model.translate-button` が
  あり、中の `tp-yt-paper-button` が「日本語に翻訳」。押すと `state` が `untoggled` から `toggled` になり、文言が
  「原文を見る（Google による翻訳）」になる。本文（`#content-text`、`yt-attributed-string`）は同じ要素のまま中身が変わる。
- `yt-attributed-string` は custom element なので、`cloneNode` で写しを作らない（写しが自分で描画を始める）。
