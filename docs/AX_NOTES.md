# 対象アプリの AX 構造メモ

対応アプリのアクセシビリティ（AX）の構造と振る舞いを、2026 年 11 月時点の実測でまとめる。アプリの更新で変わることがある。

対応アプリ: Slack, Discord, Claude（Claude Code）, Codex, OpenCode, DeepSeek Harness、ターミナルの CLI、Safari、Google Chrome。

走査コスト（`AXUIElementCopyMultipleAttributeValues` で 1 要素 1 IPC）:
Slack 435 要素 25ms、Discord 1700 要素 62ms、Safari 318 要素 20ms、メッセージ 72 要素 22ms。

## Chromium / Electron 共通

- Electron アプリに `AXManualAccessibility = true` を設定すると、数秒後に Web 部分の AX ツリーが現れる
  （`AXEnhancedUserInterface` は Electron では未対応 = -25208）。
- Chromium は `AXDOMClassList`（DOM の class 一覧）を公開するので、アプリ別ルールは主に DOM クラス接頭辞で書く。
- Chromium は AX の frame をスクロール領域で切り取って返す。仮想リストの画面外の項目は、スクロール領域の上端に
  「幅いっぱい × 高さ 1pt」で押し込まれる。→ 高さ 3pt 未満の要素は不可視として扱う。
- ウインドウを別のディスプレイに移した直後、Chromium が Web 部分の frame を半分の倍率で返すことがある（Slack で確認）。
  抽出側（FrameTransform）で検出して補正する。マウス下の範囲と選択範囲の矩形は補正されない。

### 原文の見た目

- AXStaticText は `AXNumberOfCharacters` / `AXAttributedStringForRange` の値を返さないが、`AXTextMarkerRangeForUIElement` →
  `AXAttributedStringForTextMarkerRange` で `AXFont = {AXFontSize}`（ファミリ名なし）と `AXForegroundColor`（CGColor）が
  取れる。`AXAttributedStringForTextMarkerRangeWithOptions` は -25212。
- run の矩形は文字の大きさと同じ高さ（16px の文字で 16pt）で、ラテン文字のディセンダは矩形の下にはみ出す。
- `AXFontSize` はページのズーム（Electron のズーム設定、CSS zoom）を含まない（CSS zoom 1.25 のページでも 16）。

### リンク

テスト用のページを一時プロファイルの Chrome で確認した。

- リンクは `AXLink`（子に `AXStaticText`）。強調などで深くなっても、`AXLink` の下の文字はすべてリンクの一部。
- `AXURL` は 1 回 0.05〜0.2ms。ページ内のリンク（`#target`）は `file://…#target` を返す。
- `AXPress` でリンクの動作（ページ内移動・クリックのハンドラ）が起きる。押した要素が消えると `AXPress` は
  -25202（invalidUIElement）。
- `AXAttributedStringForTextMarkerRange` の run には `AXForegroundColor` と `AXUnderline`（下線付きのリンク）が付く。
  リンクが段落でいちばん長い run になることがあるので、段落の色はリンクの run を除いて決める。

## Slack（com.tinyspeck.slackmacgap）

```
AXWebArea
 └ AXGroup dom=p-message_pane ...                    メッセージ欄
    └ AXGroup dom=c-scrollbar__hider                  可視領域（クリップ矩形）
       └ AXList/AXContentList dom=sr-only (frame 1x1!) ← frame は使えない
          └ AXGroup dom=c-virtual_list__item
             └ AXGroup/AXDocument rd="message" dom=c-message_kit__hover
                └ AXGroup dom=c-message_kit__actions
                   ├ AXButton dom=c-message__sender_button      送信者
                   ├ AXLink dom=c-timestamp                       時刻
                   ├ AXGroup dom=p-rich_text_section              ★本文の段落（子: AXStaticText, AXLink(メンション)）
                   ├ AXGroup dom=c-message_kit__file              添付
                   └ AXGroup dom=c-message__reply_bar_description スレッド返信数
```

- 本文ブロック: `p-rich_text_section`, `p-rich_text_list`, `p-rich_text_quote`。コード: `p-rich_text_preformatted`。
- メッセージ一覧は `AXList/AXContentList dom=sr-only`（frame 1x1）。Slack のルールで `sr-only` を除外してはいけない。

## Discord（com.hnc.Discord）

```
AXGroup dom=scroller__* (可視領域)
 └ AXList/AXContentList dom=scrollerInner__*
    └ AXGroup dom=messageListItem__*
       └ AXGroup/AXDocumentArticle rd=<ローカライズ: "メッセージ"> dom=message__*,cozyMessage__*
          ├ AXHeading dom=header_*   (username_*, AXTimeGroup, hiddenVisually_*)
          ├ AXGroup dom=markup__*,messageContent_*   ★本文（子: AXStaticText, AXLink など）
          └ AXGroup dom=container_* → AXDocumentArticle dom=embedFull__* → embedDescription__* など
```

- クラス名の後ろはハッシュ（`_c19a55`）なので接頭辞で照合する。roleDescription は言語設定で変わるので使わない。
- 返信のプレビュー（`repliedTextContent_`）も `messageContent_` を持つので除外する。`timestamp_` は本文中の「(編集済)」。
- メンション（role="button" の span）は子のない `AXButton` として出る。URL はなく、押すしかない。

## Claude デスクトップ（com.anthropic.claudefordesktop）の Claude Code タブ

Tailwind のユーティリティクラスが中心。メッセージ単位は `group/message-row`。
ツール実行などの状態行は `group/status`（除外）。`sr-only` はスクリーンリーダー専用の重複テキスト（除外）。

```
AXGroup dom=group/message-row,relative,flex,w-full
 ├ AXGroup → AXStaticText（本文。長い段落は 1 つの AXStaticText）
 └ AXGroup dom=contents → AXGroup dom=group/status ... (ツール実行の要約) ← 除外
```

- `epitaxy-chat-panel-body` をコンテナにすると、走査する要素が 167 → 96 に減る。`group/tool` も除外する。
- サイドチャットは右側のペイン（`AXGroup/AXLandmarkRegion`、タブ付き）。名前の付いたクラスがなく、会話のスクロール領域
  `h-full,overflow-y-auto,overflow-x-hidden,[contain:strict],[scrollbar-gutter:stable_both-edges],…` の中に、
  メインと同じ `AXDocumentArticle` → `group/message-row` が並ぶ。`[scrollbar-gutter:stable_both-edges]` を持つのは
  メインとサイドの会話のスクロール領域だけなので、これをコンテナに加える（メインのものは `epitaxy-chat-panel-body` の中で、
  そちらが先に一致する）。自分のメッセージ（`rounded-[var(--cds-message-bubble-radius)]` の吹き出し）はどちらも
  `group/message-row` の外にあり、訳さない。
- サイドチャットを開いた直後は、見えている行まで「幅いっぱい × 高さ 1pt」で返ることがある。数秒でそろう。
- メインとサイドは別々にスクロールする。コンテナごとの範囲（`WindowSnapshot.scrollRegions`）で、スクロールした側の
  訳文だけを隠す。左のスレッド一覧（`AXLandmarkComplementary`）のスクロールでは何も隠さない。
- ファイル参照は本文中の葉の `AXButton`（DOM クラス `inline box-decoration-clone prose-link`、子なし、URL なし）。
  境界として扱うと段落が 2 つに割れ、後半の外接矩形が前半の 2 行目に重なる（訳文どうしが重なって見える）ので、
  文の一部として扱う。

## OpenCode デスクトップ（ai.opencode.desktop）

```
AXGroup dom=scroll-view → AXGroup/AXLandmarkRegion dom=scroll-view__viewport   ★本文領域
 ├ AXGroup dom=pointer-events-none,sticky,top-0   ヘッダ（除外）
 └ AXGroup ... 段落ごとの AXGroup（子: AXStaticText, AXGroup/AXCodeStyleGroup(インラインコード),
                AXGroup/AXStrongStyleGroup(太字), AXList/AXContentList + AXListMarker）
    └ AXGroup dom=tool-collapsible  ツール実行（除外）
```

## DeepSeek Harness（com.deepseek.dsh）

Electron。DOM クラスは `ハッシュ_名前`（例 `tnXGgG_column`）で、前方一致の規則にはハッシュが入る。

```
AXWebArea → … → AXGroup dom=PIRFFq_frame
 ├ AXButton dom=kB3qhq_newSession ほか            サイドバー上部（子として並ぶだけで、まとめる要素はない）
 ├ AXStaticText                                     サイドバーの見出し
 ├ AXGroup dom=Kjh-qa_treeBody
 │  └ AXOutline dom=Kjh-qa_list                     スレッド一覧（ランドマークではない）
 │     └ AXGroup dom=Kjh-qa_groupSection → AXRow/AXOutlineRow dom=JoiKIa_projectRow / JoiKIa_sessionRow
 └ AXGroup dom=kiGsTW_root
    ├ AXGroup/AXLandmarkBanner dom=kiGsTW_header
    └ AXGroup dom=kiGsTW_body → kiGsTW_scrollBody
       ├ AXGroup dom=tnXGgG_frame → tnXGgG_root → tnXGgG_column   ★会話（段落ごとの AXGroup、子に AXCodeStyleGroup）
       └ AXGroup dom=kiGsTW_composerSeat                           入力欄
```

- スレッド一覧は `AXOutline` で、`AXLandmarkNavigation` ではない。汎用の Web チャット規則は `AXOutline` を除外する
  （除外しないとスレッド名が訳される）。
- 汎用の Web チャット規則（AXWebArea 内の段落まとめ、コードブロック・ナビゲーション・ツリー除外）で扱い、未検証とする。

## ブラウザ（Safari / Google Chrome）

記事風のテスト用ページ（ヘッダ・nav・検索欄・本文・コードブロック・表・サイドバー・コメント欄・フッタ）と、
Wikipedia・MDN・GitHub のページで確認した（Safari 27、Chrome 156）。

```
Safari:  AXWindow → AXSplitGroup → AXTabGroup → AXGroup id=BrowserView… → AXGroup → AXScrollArea → AXWebArea
Chrome:  AXWindow → AXGroup dom=BrowserRootView → … → AXGroup dom=ContentsContainerView → AXScrollArea → AXWebArea
AXWebArea → AXGroup/AXLandmarkBanner（nav = AXLandmarkNavigation、検索 = AXLandmarkSearch）
          → AXGroup/AXLandmarkMain → AXGroup/AXDocumentArticle → AXHeading, AXGroup(段落), AXList/AXContentList, AXTable
          → AXGroup/AXLandmarkComplementary（サイドバー）→ AXGroup/AXLandmarkContentInfo（フッタ）
```

- Safari は何もしなくても Web の AX ツリーを出す。Chrome は `AXManualAccessibility` に -25205 を返し、
  `AXEnhancedUserInterface` をオンにしたときだけ出す。Chrome はこの設定に（オンにもオフにも）-25208
  （notImplemented）を返すが、値は変わり、ツリーも作られる・捨てられる。→ 設定したあとに読み直した値で成否を決める
  （`AppAccessibilityEnabler.outcome`）。エラーを失敗とみなすと、ウォームアップが始まらず、終了時にも戻さない。
  オンにしてから 3 秒でツリーはそろう。
- どちらも `AXDOMClassList` を公開し、ランドマークは subrole になる。汎用のページ規則（AXWebArea をコンテナ、
  banner・navigation・search・contentinfo・AXOutline・コードブロックを除外）で本文・見出し・リスト・表・引用が
  段落ごとに取れ、文字の大きさと色もすべて読める。サイドバー（complementary）には記事の文章もあるので除外しない。
- `<pre>`: Safari は `AXGroup/AXPreformattedStyleGroup`、Chrome は subrole のない AXGroup。中の `<code>` はどちらも
  `AXCodeStyleGroup` で、文中の `<code>` と同じ。→ AXCodeStyleGroup は除外しない（文が切れる）。
  ハイライト用のクラス（`language-`・`hljs`・`shiki`）とコード判定で落とす。
- スキップリンク（「Skip to content」、Wikipedia の `mw-jump-link`）はフォーカスされるまで 1x1 の `AXLink`。Chrome は
  中の文字も 1pt に潰すが、Safari は文字に 53x54 などの矩形を返す。→ 自分の矩形が 1x1 のリンクは見えないものとする。
- Chrome は `<span>` を subrole のない AXGroup として出す。Wikipedia の出典は `AXLink > AXGroup(mw-reflink-text) >
  "[2]"`、`AXSuperscriptStyleGroup > AXGroup > ": p1"`。インラインの要素の中にグループが 1 つだけあるときは、
  段落にせず親に渡す（親が同じ行の前後とつなぐ）。段落にすると文がそこで切れ、`[2]` は文字なしで捨てられ、
  `: p1` は矩形の重なりで段落の先頭に足される。Safari はこれらのグループを出さない。
- 読み上げ専用の `<span class="sr-only">` は、どちらも span を出さずに AXStaticText だけを残す（クラスが読めない）。
  1px の箱で折り返した矩形（例 49x68）が次の見出しと重なり、つながってしまう。今は防げない。
- 走査: 記事のページはキャッシュ後 Safari 8〜40ms、Chrome 20〜40ms。GitHub のリポジトリのページは 750 要素前後で
  Safari 200ms、Chrome 55ms。GitHub のようなアプリ風のページでは、ファイル一覧・コミットメッセージ・日付も拾う
  （サイトごとの規則がない）。そのため既定は手動。
- テスト用に Chrome を起動すると、`open -n -g` でも約 2 秒後に前面に出る。macOS はほかのアプリで押したリンクを
  いちばん新しい Chrome のインスタンスで開くことがある。同じ `--user-data-dir` で Chrome を起動し直すと、
  URL はそのインスタンスの新しいタブで開く。

## ターミナル（Claude Code / Codex / OpenCode の CLI）

Terminal.app:

```
AXWindow → AXSplitGroup → AXScrollArea → AXTextArea (value = 画面のテキスト全体), AXScrollBar
```

- `AXVisibleCharacterRange` と `AXBoundsForRange` で可視行とその矩形を得る。TUI の罫線（│╭╮╰╯─）、スピナー行、
  プロンプト行を除き、折り返された行を連結して段落にする。Claude Code 風の画面では罫線・ツール呼び出し・スピナー行を
  除いた 5 段落を 5〜15 ms で読む。
- `AXBoundsForRange` はセルの矩形（例 9x17）を返すが、`AXAttributedStringForRange` と `AXTextMarkerRangeForUIElement`
  は -25213。罫線などの AXStaticText は `AXFont = {}`。
- ウインドウ幅で折り返された行は値の中では 1 行で、その範囲の矩形は複数行の外接矩形（例 1080x34）になる。

Ghostty（com.mitchellh.ghostty）では AXTextArea の値と `AXVisibleCharacterRange` は読めるが、`AXBoundsForRange` がない。
行の矩形が取れないので、今はターミナルモードで訳せない（`AXLineForIndex` は画面上の行ではなく論理行を数える）。

## 画面のロック中

画面がロックされている間、AX の窓は `AXApplication` を返し（frame なし）、走査しても何も見つからない（Terminal・Chrome・Finder で確認）。
