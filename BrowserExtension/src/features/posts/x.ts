import { isForeign, ROW_TAG, type Post, type PostSite } from "./site";

/**
 * X (x.com and X Pro at pro.x.com, which draw posts the same way).
 *
 * A post's text is `[data-testid="tweetText"]`, with the post's language in `lang`. Where X translates a post by
 * itself (with Grok), a row sits right before the text:
 *
 *   translated:  [Grok icon] 英語からの翻訳 [原文を表示] [自動翻訳について]
 *   original:    [Grok icon] [翻訳を表示] [自動翻訳について]
 *
 * The text element stays the same one; X swaps what is in it and its `lang`. The row is read by its shape, not its
 * words, which change with X's display language: the label is the only `span` among the row's children, and the
 * switch is the button with text (the other button holds only an icon). A quoted post shows the translation
 * without the switch, so its original cannot be had and it gets no button.
 *
 * Posts in another language that X did not translate have no row at all; they get a row of ours with the button.
 * (docs/BROWSER_EXTENSION_NOTES.md has what was seen in the browser.)
 */
const TEXT = 'article[data-testid="tweet"] [data-testid="tweetText"]';

export const xPosts: PostSite = {
  id: "x",
  matches: (url) => url.hostname === "x.com" || url.hostname === "pro.x.com",
  automatic: { name: "Grok", setting: "replaceGrokTranslation" },
  needsTarget: true,
  css: `
    plamonic-post-button {
      display: inline-flex; align-items: center; vertical-align: top; min-height: 22px;
      margin: -3px 0 0; padding: 0 4px; font-size: 13px; line-height: 16px; font-weight: 400;
      color: rgb(29, 155, 240);
    }
    ${ROW_TAG} { display: block; margin: 0 0 2px -4px; padding-top: 3px; font-size: 13px; line-height: 16px; }
  `,
  posts(target) {
    const posts: Post[] = [];
    for (const text of document.querySelectorAll<HTMLElement>(TEXT)) {
      const post = read(text, target);
      if (post) posts.push(post);
    }
    return posts;
  },
  read,
};

function read(text: HTMLElement, target: string | undefined): Post | undefined {
  if (!text.isConnected) return undefined;
  const row = translationRow(text);
  if (row) {
    const children = [...row.children];
    const translated = children.some((child) => child.tagName === "SPAN" && hasText(child));
    const toggle = children.find((child): child is HTMLElement => child.tagName === "BUTTON" && hasText(child));
    if (translated && !toggle) return undefined;
    return {
      text,
      toggle,
      translated,
      place(button) {
        ownRow(text)?.remove();
        // Last in the row: X draws its buttons anew when the post is switched, which puts them after ours.
        if (row.lastElementChild !== button) row.append(button);
      },
    };
  }
  // A quoted post is one link to the post: no room for a row, and X shows its translation without a way back.
  if (!isForeign(text.getAttribute("lang"), target) || text.closest('[role="link"]')) return undefined;
  return {
    text,
    translated: false,
    place(button) {
      let row = ownRow(text);
      if (!row) {
        row = document.createElement(ROW_TAG);
        text.before(row);
      }
      if (button.parentElement !== row) row.append(button);
    },
  };
}

/** X's translation row: the element before the text (before our own row, when X adds its row later) that starts with the icon. */
function translationRow(text: HTMLElement): HTMLElement | undefined {
  let previous = text.previousElementSibling;
  while (previous && isOwnRow(previous)) previous = previous.previousElementSibling;
  if (!(previous instanceof HTMLElement) || previous.getAttribute("dir") !== "ltr") return undefined;
  return previous.firstElementChild?.tagName.toLowerCase() === "svg" ? previous : undefined;
}

function ownRow(text: HTMLElement): Element | undefined {
  const previous = text.previousElementSibling;
  return previous && isOwnRow(previous) ? previous : undefined;
}

const isOwnRow = (element: Element) => element.tagName.toLowerCase() === ROW_TAG;
const hasText = (element: Element) => /\S/.test(element.textContent ?? "");
