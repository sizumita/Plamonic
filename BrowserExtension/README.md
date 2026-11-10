# Plamonic ブラウザ拡張機能

Safari と Chrome で同じコードを使う Plamonic の拡張機能（Manifest V3、TypeScript）。ページから文章を集めて表示し、
翻訳は Mac の Plamonic が行う（アプリ側の受け口は [docs/DESIGN.md](../docs/DESIGN.md) の 9 章）。

いまの機能は次のとおり（使い方は [docs/USAGE.ja.md](../docs/USAGE.ja.md#ブラウザの拡張機能)）。

- YouTube の字幕: 動画の上の字幕を訳文で書き換える（訳文／訳文＋原文／元の字幕。既定は元の字幕で、そのあいだは字幕を訳さない。
  メニューで訳文にするか、サイドバーを開くと訳し始める）。
- YouTube の字幕: サイドバーに時刻つきの字幕一覧を出し、再生中の行をハイライトして自動スクロールする。行をクリックすると
  その位置へ移動する。
- ページの翻訳: 画面に見えている段落から訳し、残りもあとから訳す。段落の中のリンク・太字などの書式・コード・アイコン・改行は
  訳文でも残す。訳した段落にポインタを止めると原文を出す。どこを訳すかと自動で訳すかは、Plamonic の設定「Webサイト」で決める。
- ツールバーのメニュー: そのページで使える機能（ページの翻訳、サイドバー、自動翻訳の一時停止など）を出す。

## ビルドとテスト

```bash
npm install
npm run build        # dist/chrome（ストア用）、dist/chrome-unpacked（アプリに同梱）、dist/safari
npm run build:dev    # 開発用（ソースマップつき、検証用の Native Messaging ホストと拡張機能 ID を使う）
npm test             # 字幕の読み取り、文のまとめ方、トラックの選び方、アプリとの同期、ページ翻訳の印の付け外し
npm run typecheck
```

- Chrome: `chrome://extensions` のデベロッパーモードで `dist/chrome`（`npm run build:dev`）を読み込む。Plamonic を起動しておけば、
  アプリが Chrome に Native Messaging ホスト（アプリ内の `Contents/Helpers/plamonic-chrome-host`）を登録している。
- ベータ版のアプリを使う人は、アプリに入っている拡張機能を読み込む（設定 >「一般」>「ブラウザ」の「ベータ版の Chrome
  拡張機能」）。Plamonic のビルドが `dist/chrome-unpacked` を `Contents/Resources/ChromeExtension` に入れる。
  リリースは Chrome ウェブストアに出す（docs/DEVELOPMENT.md の「Chrome Web Store」）。
- Safari: Plamonic のビルドが `dist/safari` を `PlamonicSafariExtension.appex` に入れる（`scripts/build-web-extension.sh`）。
  隠しフォルダ（`.claude/` など）の中のアプリの拡張機能は Safari に出ないので、`~/Applications` に置いて起動する。

## 構成

```
src/
  background/   アプリとの通信（native messaging）、サイドバーの開き方のブラウザ差
  content/      ページで動く土台: 機能の選択と切り替え、サイドバーへの配信、Safari のページ内サイドバー
    feature.ts        機能のインターフェース（Feature / FeatureInstance / FeatureContext）
    document-sync.ts  文章の一覧をアプリの「文書」として訳す（字幕にもページ翻訳にも使える）
  features/     機能ごとのコード（youtube/ と page/）
  popup/        ツールバーのメニュー
  sidebar/      サイドバーの画面: SidebarShell と、表示の種類ごとのビュー（views/）
  shared/       ブラウザ API、メッセージの型、アプリとのメッセージの型、設定
static/         アイコン、サイドバーとメニューのページ
```

- **ブラウザの差は小さく閉じ込める。** `__BROWSER__`（ビルド時の定数）で分けているのは、サイドバーの開き方だけ。
  Chrome は `chrome.sidePanel`、Safari はサイドパネルの API がないので、同じ `SidebarShell` をページ内の shadow root に置く
  （拡張機能のページを iframe でページに入れると Safari が落ちた）。
- **ページ側の土台と機能を分ける。** content script は URL に合う機能を 1 つ動かし、ページが変われば止めて作り直す。
  機能はアプリとの通信、ページへのスクリプトの注入、サイドバーへの表示を `FeatureContext` 経由で行う。
- **サイドバーは表示の種類で切り替える。** 機能は `view()` で `{ kind, ... }` を返し、サイドバーは `kind` に登録された
  ビューで描く。サイドバーが開いているあいだだけ、機能の更新が届く（Chrome はポート、Safari はページ内で直接）。

### サイトごとの設定

どのサイトをどう訳すか（自動／手動／オフ、翻訳する場所・しない場所の CSS セレクタ、翻訳先言語など）は、拡張機能では
持たず、Plamonic の設定「Webサイト」で管理する（[DESIGN.md 9.4](../docs/DESIGN.md)）。content script はページを開くと
アプリに設定を聞き、ページ翻訳は翻訳する場所の中だけを訳す。自動のサイトでは、メニューから一度だけそのサイトへの許可を
求め、許可されたサイトに content script を登録する（`background/automatic-sites.ts`）。

### 機能を足すには

1. `src/features/<名前>/` に `Feature` を書く（`matches`、`create`、`FeatureInstance` の `start` / `stop` / `view`）。
2. `src/features/index.ts` の `FEATURES` に加える。
3. 新しいサイトなら `scripts/build.mjs` の `CONTENT_MATCHES` に加える。
4. サイドバーに独自の表示があれば、`src/sidebar/views/` にビューを書き、`views/index.ts` の `VIEWS` に `kind` で登録する。

### ページ翻訳でリンクと書式を残す方法

段落の文字は、まわりのリンクと書式の要素（`a`、`b`、`strong`、`em`、`code` など）で区切って送る（`features/page/rich-text.ts`）。
印の付け方はアプリが画面のリンクに使うものと同じ（[DESIGN.md 6.1](../docs/DESIGN.md)「訳文の中のリンク」、`features/page/markup.ts`）。

- リンク・書式の中の言葉は `[文字](番号)` で送り、訳文の印の位置に、元の要素の写し（`href`、`class`、`style` などの属性つき）を
  置いて訳した文字を入れる。語順が変わってもよく、入れ子（太字の中のリンク）もそのまま組み直す。
- コードと、文字が URL・@メンション・#番号などのリンクは印なしで送り、訳文の同じ文字の位置に元の要素を丸ごと写す
  （大文字小文字・全角の違いは原文に戻す）。
- `<br>` は改行として送り、訳文の改行を `<br>` に戻す。文字のない要素（アイコン、画像、絵文字の画像）は、隣にあった
  リンクなどと一緒に置く（段落の先頭にあったものは先頭、それ以外は末尾）。
- 段落の文字をすべて 1 つの要素が持つとき（見出しが丸ごとリンク）は、その要素の中だけを書き換える（サイトのクリックの処理が残る）。
  それ以外のリンクは写しなので、ページの JavaScript が要素に直接付けた処理は効かない（`href` での移動は効く）。
- 印が崩れて返ったときは印を除いた訳文をふつうの文字で出す（リンクの文字が訳文にそのまま残っていれば、そこはリンクにする）。
  span などの見た目のための要素は残さない（段落の要素の書式は効く）。「原文に戻す」は元の要素をそのまま戻す。

### YouTube の字幕の取り方

字幕のサーバーはプレーヤーの proof-of-origin トークン（`pot=`）つきのリクエストにしか答えないので、ページの JavaScript の
世界で動く `page-hook.js` がプレーヤー自身の字幕リクエストを拾い、同じ URL の `lang` / `kind` を変えて翻訳元のトラックを取る。
プレーヤーは字幕がオンのときしか字幕を取りに行かないので、取れるまで字幕ボタンを切り替える（YouTube の字幕は訳文の後ろに
隠す）。詳しい検証結果は [docs/BROWSER_EXTENSION_NOTES.md](../docs/BROWSER_EXTENSION_NOTES.md)。
