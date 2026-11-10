import type { Settings } from "../../shared/settings";

/** The on/off settings that replace a site's automatic translation. */
export type AutomaticSetting = { [K in keyof Settings]: Settings[K] extends boolean ? K : never }[keyof Settings];

/**
 * A site whose posts (or comments) have a translation control of their own, such as X's 「翻訳を表示」 and the
 * 「日本語に翻訳」 under a YouTube comment. The post buttons feature (index.ts) puts 「PLaMoで翻訳」 next to that
 * control; the site says where its posts are and how its control works.
 *
 * Adding a site: write a PostSite, add it to POST_SITES in index.ts, and add its address to POST_MATCHES in
 * scripts/build.mjs so the content script runs there.
 */
export interface PostSite {
  id: string;
  matches(url: URL): boolean;
  /** How the button (`plamonic-post-button`) and our own row look here, to sit well next to the site's control. */
  css: string;
  /** `posts` uses the target language, so the app is asked for it when the page opens. */
  needsTarget?: boolean;
  /**
   * The posts on the page that get a button now. `target` is the language Plamonic translates into here (undefined
   * while the app has not answered): a site that states each post's language may also offer posts in another
   * language that have no control of the site's.
   */
  posts(target: string | undefined): Post[];
  /** One post again, by its text element (its state after the site's control was used); undefined when it is gone. */
  read(text: HTMLElement, target: string | undefined): Post | undefined;
  /**
   * The site translates posts by itself, without being asked (X, with Grok): the toolbar menu then offers to have
   * PLaMo translate those posts instead. `name` is who translates, for the menu; `setting` is where the choice is kept.
   */
  automatic?: { name: string; setting: AutomaticSetting };
}

export interface Post {
  /** The element that holds the post's text. It identifies the post. */
  text: HTMLElement;
  /** The site's control that switches between its translation and the original. */
  toggle?: HTMLElement;
  /** `text` holds the site's translation now, not the original. */
  translated: boolean;
  /** Puts our button next to the site's control, or in a row of our own. Called on every scan: it must not move a button that is in place. */
  place(button: HTMLElement): void;
}

/** A row of our own for the button, on posts without a control of the site's. */
export const ROW_TAG = "plamonic-post-row";

/**
 * Language tags that say a post has nothing to translate: undetermined, no words, and the private-use codes X
 * gives posts that are only media, links, mentions, hashtags or emoji (`qme`, `qam`, `qht`, `art`, …).
 */
const NOT_A_LANGUAGE = /^(und|zxx|art|mul|q[a-t][a-z])$/;

/** The primary subtag, lower case: "pt-BR" → "pt". */
export function baseLanguage(tag: string): string {
  return tag.trim().toLowerCase().split(/[-_]/)[0] ?? "";
}

/** Whether a post in `language` (as the site states it) is worth offering a translation into `target` for. */
export function isForeign(language: string | null | undefined, target: string | undefined): boolean {
  if (!language || !target) return false;
  const base = baseLanguage(language);
  if (!base || NOT_A_LANGUAGE.test(base)) return false;
  return base !== baseLanguage(target);
}
