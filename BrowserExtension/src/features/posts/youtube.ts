import type { Post, PostSite } from "./site";

/**
 * YouTube comments and replies. Under a comment in another language YouTube puts 「日本語に翻訳」
 * (`ytd-tri-state-button-view-model.translate-button`, whose `state` is `untoggled` or, while Google's translation
 * shows, `toggled`). The comment's text stays the same element (`#content-text`); YouTube swaps what is in it.
 * Comments without that control (already in the reader's language) get no button.
 */
const TEXT = "ytd-comment-view-model #content-text";
const CONTROL = "#main > ytd-tri-state-button-view-model.translate-button";

export const youtubeComments: PostSite = {
  id: "youtube",
  matches: (url) => url.hostname === "www.youtube.com",
  css: `
    plamonic-post-button {
      display: inline-flex; align-items: center; margin-left: 12px;
      font-size: 1.4rem; line-height: 2rem; font-weight: 500;
      color: var(--yt-spec-text-secondary, #606060);
    }
  `,
  posts() {
    const posts: Post[] = [];
    for (const text of document.querySelectorAll<HTMLElement>(TEXT)) {
      const post = read(text);
      if (post) posts.push(post);
    }
    return posts;
  },
  read,
};

function read(text: HTMLElement): Post | undefined {
  if (!text.isConnected) return undefined;
  const control = text.closest("ytd-comment-view-model")?.querySelector<HTMLElement>(CONTROL);
  const toggle = control?.querySelector<HTMLElement>("tp-yt-paper-button");
  if (!control || !toggle || control.hidden) return undefined;
  return {
    text,
    toggle,
    translated: control.getAttribute("state") === "toggled",
    place(button) {
      if (control.lastElementChild !== button) control.append(button);
    },
  };
}
