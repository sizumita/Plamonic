import type { PageAction } from "../../shared/actions";
import { updateSettings, type Settings } from "../../shared/settings";
import { DocumentSync, type SyncItem } from "../../content/document-sync";
import type { Feature, FeatureContext, FeatureInstance } from "../../content/feature";
import { showToast } from "../../content/toast";
import { normalizeText } from "../page/blocks";
import { OriginalPopup } from "../page/original-popup";
import { planParagraph, renderTranslation, type Paragraph } from "../page/rich-text";
import { ROW_TAG, type Post, type PostSite } from "./site";
import { xPosts } from "./x";
import { youtubeComments } from "./youtube";

/** The sites whose posts get the button. Their addresses are also in POST_MATCHES in scripts/build.mjs. */
export const POST_SITES: PostSite[] = [xPosts, youtubeComments];

/**
 * 「PLaMoで翻訳」 next to a site's own translation control on each post or comment: pressing it shows PLaMo's
 * translation of that one post in place of its text, and pressing it again puts the original back. Where the site
 * translates posts by itself (X, with Grok), the toolbar menu can have those posts shown in PLaMo's translation
 * instead.
 *
 * The post's own text element is never written into: the sites redraw it themselves when their control is used
 * (X swaps Grok's translation and the original inside the same element), and a framework that finds its nodes gone
 * breaks the page. The translation goes into a copy of the element placed after it, and the original is hidden.
 *
 * The posts asked for are one document in the app (content/document-sync.ts), so they are translated like a page's
 * paragraphs: a draft first where there is a draft model, links and formatting kept. Nothing is sent before a
 * button is pressed (or a post is replaced by the setting).
 */
export const postButtons: Feature = {
  id: "post-buttons",
  activation: "auto",
  matches: (url) => siteFor(url) !== undefined,
  create: (context) => new PostButtons(context, siteFor(new URL(location.href))!),
};

function siteFor(url: URL): PostSite | undefined {
  return POST_SITES.find((site) => site.matches(url));
}

const BUTTON_TAG = "plamonic-post-button";
const COPY_ATTRIBUTE = "data-plamonic-post-translation";
const HIDDEN_ATTRIBUTE = "data-plamonic-post-hidden";
const STYLE_ID = "plamonic-posts-style";
/** Page translation translates the posts themselves while it runs, so the buttons step aside. */
const PAGE_TRANSLATION = "page-translation";

const BASE_CSS = `
  ${BUTTON_TAG} { cursor: pointer; white-space: nowrap; user-select: none; -webkit-user-select: none; }
  ${BUTTON_TAG}:hover { text-decoration: underline; }
  ${BUTTON_TAG}:focus-visible { outline: 2px solid currentColor; outline-offset: 1px; border-radius: 4px; }
  ${BUTTON_TAG}[data-state="pending"] { opacity: .65; }
  [${HIDDEN_ATTRIBUTE}] { display: none !important; }
`;

const LABELS = {
  idle: "PLaMoで翻訳",
  pending: "PLaMoで翻訳中…",
  shown: "原文に戻す（PLaMo）",
  failed: "PLaMoで翻訳できませんでした（もう一度）",
} as const;

/** How long the site gets to put the original back after its control is pressed for it. */
const REVERT_TIMEOUT_MS = 3000;
/** Translations remembered for posts the site draws again (a timeline takes posts out as they scroll away). */
const MAX_REMEMBERED = 500;

interface Entry {
  id: string;
  text: HTMLElement;
  button: HTMLElement;
  state: keyof typeof LABELS;
  /** The site's control was pressed for us and the original is not back yet. */
  reverting: boolean;
  /** The button was pressed (not the setting that replaces the site's translations): problems are said aloud. */
  byUser: boolean;
  /** The post's text when it was sent; the post is taken as another one once the site shows something else. */
  source?: string;
  paragraph?: Paragraph;
  /** The translation shown now, and whether it is the last one to come. */
  result?: string;
  settled: boolean;
  /** Our copy of the text element, holding the translation. */
  copy?: HTMLElement;
}

/** Exported for the fixture pages that try it against a stand-in of a site. */
export class PostButtons implements FeatureInstance {
  private entries = new Map<HTMLElement, Entry>();
  /** Posts the reader chose a side for (our button or the site's control): the replace setting leaves them alone. */
  private manual = new WeakSet<HTMLElement>();
  /** Posts whose site translation was switched off by the replace setting, with that translation: once per text. */
  private replaced = new WeakMap<HTMLElement, string>();
  private remembered = new Map<string, string>();
  private sync: DocumentSync | undefined;
  private sentIds = "";
  private counter = 0;
  private target: string | undefined;
  private targetAskedAt = 0;
  private observer: MutationObserver | undefined;
  private scanTimer: ReturnType<typeof setTimeout> | undefined;
  private warned = false;
  private stopped = false;
  private readonly onClick = (event: MouseEvent) => this.siteControlClicked(event);
  private popup = new OriginalPopup(
    `[${COPY_ATTRIBUTE}]`,
    () => this.copies(),
    (element) => this.entryOfCopy(element)?.source,
  );

  constructor(
    private readonly context: FeatureContext,
    private readonly site: PostSite,
  ) {}

  start() {
    this.ensureStyle();
    this.observer = new MutationObserver(() => this.scheduleScan());
    this.observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true,
      attributes: true,
      // What the sites change when their control is used: YouTube's button state, the language of X's text.
      attributeFilter: ["state", "lang"],
    });
    document.addEventListener("click", this.onClick, true);
    this.popup.attach();
    if (this.site.needsTarget) void this.askTarget();
    this.scheduleScan();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.scanTimer);
    this.observer?.disconnect();
    document.removeEventListener("click", this.onClick, true);
    this.popup.detach();
    for (const entry of [...this.entries.values()]) this.drop(entry);
    this.sync?.stop();
    this.sync = undefined;
    document.getElementById(STYLE_ID)?.remove();
  }

  /** The sites are single-page: the same posts stay under a photo or a reply box that changes the address. */
  urlChanged(url: URL) {
    return this.site.matches(url);
  }

  settingsChanged() {
    this.scheduleScan(0);
  }

  actions(): PageAction[] {
    const automatic = this.site.automatic;
    if (!automatic || this.context.site()?.mode === "off") return [];
    return [
      {
        id: "replace",
        kind: "choice",
        label: `${automatic.name} の自動翻訳`,
        value: this.replacing() ? "plamo" : "site",
        options: [
          { value: "site", label: "そのまま" },
          { value: "plamo", label: "PLaMoで訳す" },
        ],
      },
    ];
  }

  perform(action: string, value?: string) {
    const automatic = this.site.automatic;
    if (action !== "replace" || !automatic || (value !== "site" && value !== "plamo")) return;
    void updateSettings({ [automatic.setting]: value === "plamo" } as Partial<Settings>);
  }

  private replacing(): boolean {
    const automatic = this.site.automatic;
    return automatic !== undefined && this.context.settings()[automatic.setting];
  }

  // MARK: Finding posts

  /** Soon, and at most once in `delay` however much the page changes. */
  private scheduleScan(delay = 200) {
    if (this.stopped) return;
    if (this.scanTimer !== undefined) {
      if (delay > 0) return;
      clearTimeout(this.scanTimer);
    }
    this.scanTimer = setTimeout(() => {
      this.scanTimer = undefined;
      this.scan();
    }, delay);
  }

  private scan() {
    if (this.stopped) return;
    if (this.site.needsTarget && !this.target && Date.now() - this.targetAskedAt > 60_000) void this.askTarget();
    // A site set to オフ in the app is not translated at all.
    const posts = this.context.site()?.mode === "off" ? [] : this.site.posts(this.target);
    if (this.context.isRunning(PAGE_TRANSLATION)) {
      for (const entry of [...this.entries.values()]) this.drop(entry);
      // Page translation takes the original once the site's translation is out of the way.
      if (this.replacing()) for (const post of posts) this.switchOffSiteTranslation(post);
    } else {
      const seen = new Set<HTMLElement>();
      for (const post of posts) {
        seen.add(post.text);
        const entry = this.entries.get(post.text) ?? this.add(post.text);
        post.place(entry.button);
        this.keep(entry);
        if (entry.state === "idle" && !entry.reverting && this.replacing() && this.switchOffSiteTranslation(post)) {
          entry.byUser = false;
          void this.translate(entry, true);
        }
      }
      for (const entry of [...this.entries.values()]) if (!seen.has(entry.text)) this.drop(entry);
    }
    this.sendItems();
    // What this scan changed is not news.
    this.observer?.takeRecords();
  }

  /**
   * Presses the site's control on a post it translated by itself, so the post shows its original (the replace
   * setting). Once per translation: never again for a post the reader switched back, or one that did not switch.
   */
  private switchOffSiteTranslation(post: Post): boolean {
    if (!post.translated || !post.toggle || this.manual.has(post.text)) return false;
    const shown = normalizeText(post.text.textContent ?? "");
    if (this.replaced.get(post.text) === shown) return false;
    this.replaced.set(post.text, shown);
    post.toggle.click();
    return true;
  }

  /** Undoes `switchOffSiteTranslation` (which then leaves the post alone: it knows this translation). */
  private switchOnSiteTranslation(text: HTMLElement) {
    const post = this.site.read(text, this.target);
    if (post && !post.translated && post.toggle && this.replaced.has(text)) post.toggle.click();
  }

  private add(text: HTMLElement): Entry {
    const button = document.createElement(BUTTON_TAG);
    button.setAttribute("role", "button");
    button.tabIndex = 0;
    const entry: Entry = { id: `p${this.counter++}`, text, button, state: "idle", reverting: false, byUser: false, settled: false };
    // The sites open the post on a click anywhere in it, and have keyboard shortcuts.
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      this.pressed(entry);
    });
    button.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      event.stopPropagation();
      this.pressed(entry);
    });
    this.entries.set(text, entry);
    this.label(entry);
    return entry;
  }

  /**
   * A post we translated: back to its start when the site put other text in the element (its own translation, or
   * another comment in a reused element); else our copy stays right after the text.
   */
  private keep(entry: Entry) {
    if (entry.state === "idle" || entry.source === undefined) return;
    const stale =
      normalizeText(entry.text.textContent ?? "") !== entry.source ||
      (entry.paragraph !== undefined && !entry.text.contains(entry.paragraph.target));
    if (stale) this.reset(entry);
    else if (entry.copy && entry.copy.previousSibling !== entry.text) entry.text.after(entry.copy);
  }

  private reset(entry: Entry) {
    entry.copy?.remove();
    entry.copy = undefined;
    entry.text.removeAttribute(HIDDEN_ATTRIBUTE);
    entry.state = "idle";
    entry.source = undefined;
    entry.paragraph = undefined;
    entry.result = undefined;
    entry.settled = false;
    this.label(entry);
  }

  private drop(entry: Entry) {
    this.reset(entry);
    const parent = entry.button.parentElement;
    entry.button.remove();
    if (parent?.tagName.toLowerCase() === ROW_TAG) parent.remove();
    this.entries.delete(entry.text);
  }

  private label(entry: Entry) {
    const state = entry.reverting ? "pending" : entry.state;
    entry.button.textContent = LABELS[state];
    entry.button.setAttribute("data-state", state);
  }

  // MARK: The button

  private pressed(entry: Entry) {
    if (entry.reverting) return;
    this.manual.add(entry.text);
    entry.byUser = true;
    const state = entry.state;
    // Pressing again takes the translation away (or gives up waiting for it); after a failure it asks again.
    if (state !== "idle") this.reset(entry);
    if (state === "idle" || state === "failed") void this.translate(entry);
    this.sendItems();
  }

  /** The reader used the site's own control on a post: the replace setting leaves that post alone from now on. */
  private siteControlClicked(event: MouseEvent) {
    if (!event.isTrusted || !(event.target instanceof Node)) return;
    const target = event.target;
    for (const post of this.site.posts(this.target)) {
      if (!post.toggle?.contains(target)) continue;
      this.manual.add(post.text);
      // The site redraws the text after this click.
      this.scheduleScan(0);
      return;
    }
  }

  /**
   * Translates one post. When the site shows its own translation there, its control is pressed first and the
   * original awaited (`switched`: the replace setting already pressed it).
   */
  private async translate(entry: Entry, switched = false) {
    const current = () => this.entries.get(entry.text) === entry && !this.stopped;
    let post = this.site.read(entry.text, this.target);
    if (!post) return;
    if (post.translated || switched) {
      entry.reverting = true;
      this.label(entry);
      if (!switched) post.toggle?.click();
      post = await this.untilOriginal(entry.text);
      entry.reverting = false;
      if (!current()) return;
      if (!post) {
        this.label(entry);
        if (entry.byUser) showToast("原文を表示できませんでした。サイトの「原文を表示」を押してから試してください。", "warn");
        return;
      }
    }
    const source = normalizeText(entry.text.textContent ?? "");
    if (source.length < 2) {
      this.label(entry);
      return;
    }
    entry.source = source;
    entry.paragraph = planParagraph(entry.text);
    entry.state = "pending";
    const known = this.remembered.get(entry.paragraph.markup.input);
    if (known !== undefined) {
      entry.settled = true;
      this.show(entry, known);
    }
    this.label(entry);
    this.sendItems();
  }

  private async untilOriginal(text: HTMLElement): Promise<Post | undefined> {
    const deadline = Date.now() + REVERT_TIMEOUT_MS;
    for (;;) {
      const post = this.site.read(text, this.target);
      if (!post || !post.translated) return post;
      if (Date.now() > deadline || this.stopped) return undefined;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }

  // MARK: The app

  private async askTarget() {
    this.targetAskedAt = Date.now();
    const hello = await this.context.bridge({ type: "hello", url: location.href });
    if (!hello.ok || !hello.targetLanguage || this.stopped) return;
    this.target = hello.targetLanguage;
    this.scheduleScan(0);
  }

  /** The posts waiting for a translation (or a better one), as the app's document; none: the document is closed. */
  private sendItems() {
    const waiting = [...this.entries.values()].filter((entry) => entry.state !== "idle" && !entry.settled && entry.paragraph);
    const ids = waiting.map((entry) => entry.id).join(" ");
    if (waiting.length === 0) {
      this.sync?.stop();
      this.sync = undefined;
      this.sentIds = "";
      return;
    }
    if (this.sync && ids === this.sentIds) return;
    this.sentIds = ids;
    const items: SyncItem[] = waiting.map((entry) => {
      const { plain, input } = entry.paragraph!.markup;
      return { id: entry.id, text: plain, input: input === plain ? undefined : input };
    });
    if (this.sync) {
      this.sync.setItems(items);
    } else {
      this.sync = new DocumentSync(this.context, {
        document: `posts:${location.origin}`,
        kind: "page",
        items,
        url: location.href,
        onChange: () => this.apply(),
      });
      this.sync.start();
    }
    // All of them are wanted now, the ones asked for last first.
    this.sync.setVisible(waiting.map((entry) => entry.id).reverse());
  }

  private apply() {
    const sync = this.sync;
    if (!sync || this.stopped) return;
    const status = sync.status;
    if (status.state === "unreachable" || status.state === "disabled" || status.state === "error") {
      const unsettled = [...this.entries.values()].filter((entry) => entry.state !== "idle" && !entry.settled);
      const waiting = unsettled.filter((entry) => !entry.copy);
      if (!this.warned && waiting.some((entry) => entry.byUser)) {
        this.warned = true;
        showToast(
          status.state === "unreachable"
            ? "Plamonic が起動していません。起動してから、もう一度押してください。"
            : status.state === "disabled"
              ? "Plamonic で拡張機能への翻訳がオフです。"
              : `翻訳できませんでした: ${status.message}`,
          "warn",
        );
      }
      // Nothing is coming: the buttons go back, to be pressed again when the app is there. A draft that shows stays.
      for (const entry of unsettled) {
        if (entry.copy) {
          entry.settled = true;
          continue;
        }
        const replacing = !entry.byUser;
        this.reset(entry);
        // The site's translation is better than none: it comes back where the setting took it away.
        if (replacing) this.switchOnSiteTranslation(entry.text);
      }
      this.sendItems();
      return;
    }
    this.warned = false;
    for (const entry of this.entries.values()) {
      if (entry.state === "idle" || entry.settled || !entry.paragraph) continue;
      const result = sync.results.get(entry.id);
      if (!result) continue;
      if ((result.state === "draft" || result.state === "final") && result.text) {
        if (result.state === "final") {
          entry.settled = true;
          this.remember(entry.paragraph.markup.input, result.text);
        }
        if (result.text !== entry.result) this.show(entry, result.text);
      } else if (result.state === "skipped") {
        // Already in the language translated into, or nothing but names and links.
        if (entry.byUser) showToast("この投稿は訳す必要がありませんでした（翻訳先と同じ言語など）。");
        this.reset(entry);
      } else if (result.state === "failed" && !entry.copy) {
        entry.state = "failed";
        this.label(entry);
      }
    }
    this.sendItems();
    this.observer?.takeRecords();
  }

  private remember(input: string, translation: string) {
    this.remembered.delete(input);
    this.remembered.set(input, translation);
    if (this.remembered.size > MAX_REMEMBERED) this.remembered.delete(this.remembered.keys().next().value!);
  }

  // MARK: Showing a translation

  private show(entry: Entry, translation: string) {
    const paragraph = entry.paragraph;
    if (!paragraph || !entry.text.isConnected || !entry.text.contains(paragraph.target)) return;
    // Before the original is hidden: the copy takes its look from it.
    entry.copy ??= this.emptyCopy(entry.text);
    const copy = entry.copy;
    copy.replaceChildren(...[...entry.text.childNodes].map((node) => node.cloneNode(true)));
    // The same place in the copy as the element the translation is written into.
    let target: Node = copy;
    for (const index of pathTo(entry.text, paragraph.target)) target = target.childNodes[index]!;
    (target as Element).replaceChildren(renderTranslation(paragraph, translation).nodes);
    if (copy.previousSibling !== entry.text) entry.text.after(copy);
    entry.text.setAttribute(HIDDEN_ATTRIBUTE, "");
    entry.result = translation;
    entry.state = "shown";
    this.label(entry);
  }

  /**
   * An element that looks like the post's text element. A copy of it where that is safe; for a custom element
   * (YouTube's), whose copy would start drawing itself, a plain one with the same text style.
   */
  private emptyCopy(text: HTMLElement): HTMLElement {
    let copy: HTMLElement;
    if (text.tagName.includes("-")) {
      copy = document.createElement("plamonic-post-text");
      copy.className = text.className;
      const style = getComputedStyle(text);
      for (const property of COPIED_STYLE) copy.style.setProperty(property, style.getPropertyValue(property));
    } else {
      copy = text.cloneNode(false) as HTMLElement;
      copy.removeAttribute("id");
      copy.removeAttribute("data-testid");
      copy.removeAttribute(HIDDEN_ATTRIBUTE);
    }
    copy.setAttribute(COPY_ATTRIBUTE, "");
    // Not for page translation or the browser's own translation: it is translated already.
    copy.setAttribute("translate", "no");
    if (this.target) copy.setAttribute("lang", this.target);
    else copy.removeAttribute("lang");
    return copy;
  }

  private *copies(): Iterable<Element> {
    for (const entry of this.entries.values()) if (entry.copy) yield entry.copy;
  }

  private entryOfCopy(copy: Element): Entry | undefined {
    for (const entry of this.entries.values()) if (entry.copy === copy) return entry;
    return undefined;
  }

  private ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = BASE_CSS + this.site.css;
    (document.head ?? document.documentElement).append(style);
  }
}

const COPIED_STYLE = [
  "display", "font-family", "font-size", "font-weight", "font-style", "line-height", "letter-spacing", "color",
  "white-space", "overflow-wrap", "word-break", "text-align", "direction",
];

/** The child indexes that lead from `root` down to `node` (inside it). */
function pathTo(root: Node, node: Node): number[] {
  const path: number[] = [];
  for (let current = node; current !== root && current.parentNode; current = current.parentNode) {
    path.unshift([...current.parentNode.childNodes].indexOf(current as ChildNode));
  }
  return path;
}
