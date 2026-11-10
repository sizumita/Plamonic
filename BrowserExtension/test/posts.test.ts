import assert from "node:assert/strict";
import { test } from "node:test";
import { baseLanguage, isForeign } from "../src/features/posts/site";

test("a post in another language than the target is offered a translation", () => {
  assert.equal(isForeign("en", "ja"), true);
  assert.equal(isForeign("pt-BR", "ja"), true);
  assert.equal(isForeign("zh-Hant", "zh"), false);
  assert.equal(isForeign("JA", "ja"), false);
  assert.equal(isForeign("ja", "ja-JP"), false);
});

test("posts without words, or of unknown language, are not offered one", () => {
  // X's tags for posts that are only media, mentions, hashtags, links or emoji.
  for (const tag of ["und", "zxx", "qme", "qam", "qht", "qct", "qst", "art"]) assert.equal(isForeign(tag, "ja"), false, tag);
  assert.equal(isForeign("", "ja"), false);
  assert.equal(isForeign(null, "ja"), false);
});

test("nothing is offered while the target language is not known", () => {
  assert.equal(isForeign("en", undefined), false);
});

test("the base language is the first subtag, lower case", () => {
  assert.equal(baseLanguage("pt-BR"), "pt");
  assert.equal(baseLanguage(" EN_us "), "en");
});
