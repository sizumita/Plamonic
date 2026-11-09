import assert from "node:assert/strict";
import { test } from "node:test";
import { matchPatterns, originPatterns, validSelectors } from "../src/shared/sites";

test("site patterns become the browser's match patterns", () => {
  assert.deepEqual(matchPatterns("www.youtube.com"), ["*://www.youtube.com/*"]);
  assert.deepEqual(matchPatterns("*.wikipedia.org"), ["*://*.wikipedia.org/*"]);
  assert.deepEqual(matchPatterns("github.com/apple"), ["*://github.com/apple*"]);
  assert.deepEqual(matchPatterns("HTTPS://Example.com/Docs"), ["*://example.com/docs*"]);
  assert.deepEqual(matchPatterns("not a site"), []);
});

test("permission is asked for the whole origin", () => {
  assert.deepEqual(originPatterns("github.com/apple"), ["*://github.com/*"]);
  assert.deepEqual(originPatterns("*.wikipedia.org"), ["*://*.wikipedia.org/*"]);
});

test("invalid selectors are left out", () => {
  const probe = (selector: string) => {
    if (selector.includes("[[")) throw new SyntaxError("bad selector");
  };
  assert.deepEqual(validSelectors(["article", "div[[x", ".comment"], probe), ["article", ".comment"]);
});
