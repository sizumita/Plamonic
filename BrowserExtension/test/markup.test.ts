import assert from "node:assert/strict";
import { test } from "node:test";
import { decode, encode, isVerbatim, type MarkupRun } from "../src/features/page/markup";

const plain = (text: string): MarkupRun => ({ text, styled: false, verbatim: false });
const styled = (text: string): MarkupRun => ({ text, styled: true, verbatim: false });
const verbatim = (text: string): MarkupRun => ({ text, styled: true, verbatim: true });

test("styled runs are marked, with whitespace collapsed and moved outside the markers", () => {
  const markup = encode([plain("Read  the "), styled(" setup guide "), plain("and "), styled("FAQ"), plain(" first.")]);
  assert.equal(markup.plain, "Read the setup guide and FAQ first.");
  assert.equal(markup.input, "Read the [setup guide](1) and [FAQ](2) first.");
});

test("a paragraph without links or formatting is sent as it is", () => {
  const markup = encode([plain("  Just   text. ")]);
  assert.equal(markup.input, "Just text.");
  assert.deepEqual(decode("ただの文。", markup), [{ text: "ただの文。" }]);
});

test("translated markers become the runs' pieces, in the translation's word order", () => {
  const markup = encode([plain("Read the "), styled("setup guide"), plain(" and "), styled("FAQ"), plain(" first.")]);
  assert.deepEqual(decode("まず[FAQ](2)と[セットアップガイド](1)を読んでください。", markup), [
    { text: "まず" },
    { text: "FAQ", run: 3 },
    { text: "と" },
    { text: "セットアップガイド", run: 1 },
    { text: "を読んでください。" },
  ]);
});

test("full-width markers are read too", () => {
  const markup = encode([plain("See "), styled("the docs"), plain(".")]);
  assert.deepEqual(decode("［ドキュメント］（１）を参照。", markup), [
    { text: "ドキュメント", run: 1 },
    { text: "を参照。" },
  ]);
});

test("verbatim runs are sent unmarked and found by their text", () => {
  const markup = encode([verbatim("@alice"), plain(" fixed it in "), verbatim("src/app.ts"), plain(".")]);
  assert.equal(markup.input, "@alice fixed it in src/app.ts.");
  assert.deepEqual(decode("@aliceさんが src/app.ts で直しました。", markup), [
    { text: "@alice", run: 0 },
    { text: "さんが " },
    { text: "src/app.ts", run: 2 },
    { text: " で直しました。" },
  ]);
});

test("a verbatim run the model changed in width or case is written back as in the original", () => {
  const markup = encode([verbatim("@Alice"), plain(" agreed.")]);
  assert.deepEqual(decode("＠alice が同意しました。", markup), [{ text: "@Alice", run: 0 }, { text: " が同意しました。" }]);
});

test("a verbatim run is not found inside a longer word", () => {
  const markup = encode([verbatim("@bob"), plain(" and @bobby")]);
  assert.deepEqual(decode("@bobby と", markup), [{ text: "@bobby と" }]);
});

test("broken markers are removed and no run is placed from them", () => {
  const markup = encode([plain("See "), styled("the docs"), plain(" and "), styled("the FAQ"), plain(".")]);
  // Marker 2 went missing and a stray "](1)" is left.
  assert.deepEqual(decode("ドキュメント](1)とFAQを参照。", markup), [{ text: "ドキュメントとFAQを参照。" }]);
  // A number that was never sent.
  assert.deepEqual(decode("[ドキュメント](1)と[FAQ](7)を参照。", markup), [{ text: "ドキュメントとFAQを参照。" }]);
});

test("with broken markers, a styled run the model kept as it was is still found", () => {
  const markup = encode([plain("Made with "), styled("Plamonic"), plain(" by "), styled("Yield Space"), plain(".")]);
  assert.deepEqual(decode("Yield Space が Plamonic で作りました。", markup), [
    { text: "Yield Space", run: 3 },
    { text: " が " },
    { text: "Plamonic", run: 1 },
    { text: " で作りました。" },
  ]);
});

test("marker numbers start above the source's own list numbers", () => {
  const markup = encode([plain("Steps (1) and (2): "), styled("install"), plain(".")]);
  assert.equal(markup.input, "Steps (1) and (2): [install](3).");
  assert.deepEqual(decode("手順 (1) と (2): [インストール](3)。", markup), [
    { text: "手順 (1) と (2): " },
    { text: "インストール", run: 1 },
    { text: "。" },
  ]);
});

test("a source that already reads like markup is sent unmarked", () => {
  const markup = encode([plain("Write [text](1) for "), styled("a link"), plain(".")]);
  assert.equal(markup.input, markup.plain);
});

test("styled text with brackets is not marked", () => {
  const markup = encode([plain("See "), styled("[1]"), plain(" and "), styled("the guide"), plain(".")]);
  assert.equal(markup.input, "See [1] and [the guide](1).");
  // Unmarked, it is found by its text.
  assert.deepEqual(decode("[1] と[ガイド](1)を参照。", markup), [
    { text: "[1]", run: 1 },
    { text: " と" },
    { text: "ガイド", run: 3 },
    { text: "を参照。" },
  ]);
});

test("URLs, mentions, issue numbers, paths and camelCase names are verbatim; words are not", () => {
  for (const text of ["https://example.com/a", "www.example.com", "@alice", "#123", "README.md", "GitHub", "1.2.3"]) {
    assert.equal(isVerbatim(text), true, text);
  }
  for (const text of ["setup guide", "Python", "ドキュメント", "the FAQ"]) assert.equal(isVerbatim(text), false, text);
});

test("line breaks travel as newlines, at most one blank line, never at the ends", () => {
  const lineBreak: MarkupRun = { text: "", styled: false, verbatim: false, lineBreak: true };
  const markup = encode([lineBreak, plain("First line. "), lineBreak, plain(" Second "), styled("line"), lineBreak, lineBreak, lineBreak, plain("Third."), lineBreak]);
  assert.equal(markup.plain, "First line.\nSecond line\n\nThird.");
  assert.equal(markup.input, "First line.\nSecond [line](1)\n\nThird.");
  assert.deepEqual(decode("1行目。\n2[行目](1)\n\n3。", markup), [
    { text: "1行目。\n2" },
    { text: "行目", run: 4 },
    { text: "\n\n3。" },
  ]);
});
