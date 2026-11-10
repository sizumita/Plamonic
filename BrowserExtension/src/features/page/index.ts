import type { PageAction } from "../../shared/actions";
import { DocumentSync, type SyncItem } from "../../content/document-sync";
import type { Feature, FeatureContext, FeatureInstance } from "../../content/feature";
import { showToast } from "../../content/toast";
import { validSelectors } from "../../shared/sites";
import { BlockFinder, normalizeText } from "./blocks";
import { OriginalPopup } from "./original-popup";
import { planParagraph, renderTranslation, type Paragraph } from "./rich-text";

/**
 * Translates the page's text in place: the paragraphs on screen first, then the rest of the page, and new ones
 * as the page adds them (infinite scroll, replies). "原文に戻す" puts the original back. Started from the
 * toolbar menu on any site.
 */
export const pageTranslation: Feature = {
  id: "page-translation",
  activation: "manual",
  startLabel: "このページを翻訳",
  followsSiteMode: true,
  matches: (url) => url.protocol === "https:" || url.protocol === "http:",
  create: (context) => new PageTranslation(context),
};

interface Block {
  id: string;
  element: Element;
  text: string;
  /** Its links and formatting, and what is sent to the app (the text with them marked). */
  paragraph: Paragraph;
  /** The children of `paragraph.target` before translation, put back when translation stops. */
  original?: Node[];
  /** The app's translation shown now. */
  result?: string;
  /** Its text as shown (markers removed). */
  shown?: string;
}

/** Paragraphs on screen that are translated before anything else (the app takes up to 60). */
const MAX_VISIBLE = 60;

class PageTranslation implements FeatureInstance {
  private blocks: Block[] = [];
  private finder: BlockFinder;
  private byElement = new WeakMap<Element, Block>();
  private counter = 0;
  private sync: DocumentSync | undefined;
  /** Paragraphs on screen (or about to be), with their top on the page, for ordering them top to bottom. */
  private visible = new Map<Element, number>();
  private started = false;
  private measureTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly onViewportChange = () => this.scheduleMeasure();
  private mutations: MutationObserver | undefined;
  private rescanTimer: ReturnType<typeof setTimeout> | undefined;
  private warned = false;
  /** The original of the translated paragraph under the pointer. */
  private popup = new OriginalPopup(
    "[data-plamonic-translated]",
    () => this.translatedElements(),
    (element) => {
      const block = this.byElement.get(element);
      return block?.shown !== undefined ? block.text : undefined;
    },
  );

  constructor(private readonly context: FeatureContext) {
    // Where to translate, from the site's settings in the app.
    const site = context.site();
    const probe = (selector: string) => void document.querySelector(selector);
    this.finder = new BlockFinder(
      validSelectors(site?.include ?? [], probe).join(", "),
      validSelectors(site?.exclude ?? [], probe).join(", "),
    );
  }

  start() {
    this.addBlocks(this.finder.find(document.body));
    this.sync = new DocumentSync(this.context, {
      document: `page:${(location.origin + location.pathname + location.search).slice(0, 480)}`,
      kind: "page",
      items: this.items(),
      context: document.title,
      sourceLanguage: document.documentElement.lang || undefined,
      url: location.href,
      onChange: () => this.apply(),
    });
    // What is on screen, measured before the first request so it already goes first.
    this.measure();
    this.startSync();
    addEventListener("scroll", this.onViewportChange, { capture: true, passive: true });
    addEventListener("resize", this.onViewportChange, { passive: true });
    // Our own changes are taken out right after we make them (write), so every change seen here is the site's:
    // new paragraphs, or a site reusing an element for other text (YouTube does, for comments).
    this.mutations = new MutationObserver(() => this.scheduleRescan());
    this.mutations.observe(document.body, { childList: true, subtree: true, characterData: true });
    this.popup.attach();
  }

  private scheduleRescan() {
    clearTimeout(this.rescanTimer);
    this.rescanTimer = setTimeout(() => this.rescan(), 600);
  }

  /** Changes the page, then drops the change records it caused; records of the site's own changes still count. */
  private write(elements: Element[], change: () => void) {
    change();
    const records = this.mutations?.takeRecords() ?? [];
    const ours = (node: Node) => elements.some((element) => element === node || element.contains(node));
    if (records.some((record) => !ours(record.target))) this.scheduleRescan();
  }

  private startSync() {
    if (this.started || !this.sync) return;
    this.started = true;
    this.sync.start();
  }

  stop() {
    this.popup.detach();
    clearTimeout(this.rescanTimer);
    clearTimeout(this.measureTimer);
    removeEventListener("scroll", this.onViewportChange, true);
    removeEventListener("resize", this.onViewportChange);
    this.mutations?.disconnect();
    this.sync?.stop();
    for (const block of this.blocks) this.restore(block);
    this.mutations?.takeRecords();
  }

  /** A single-page site moved on: keep translating, new paragraphs come with the next scan. */
  urlChanged() {
    return true;
  }

  actions(): PageAction[] {
    const progress = this.sync?.progress;
    const status = this.sync?.status;
    let detail: string | undefined;
    if (status?.state === "unreachable") detail = "Plamonic が起動していません";
    else if (status?.state === "disabled") detail = "Plamonic で拡張機能への翻訳がオフです";
    else if (progress && progress.total > 0) detail = `${this.translatedCount()} / ${this.blocks.length} 段落を翻訳済み`;
    // On a site set to translate by itself, stopping is a pause: it would otherwise start again on the next page.
    if (this.context.site()?.mode === "automatic") {
      return [{ id: "pause", kind: "button", label: "このサイトの自動翻訳を一時停止", icon: "pause", detail }];
    }
    return [{ id: "stop", kind: "button", label: "原文に戻す", icon: "restore", detail }];
  }

  perform(action: string) {
    if (action === "stop") this.context.finished();
    else if (action === "pause") this.context.pauseSite();
  }

  // MARK: Paragraphs

  private addBlocks(elements: Element[]) {
    let added = 0;
    for (const element of elements) {
      if (this.byElement.has(element)) continue;
      const block: Block = {
        id: `b${this.counter++}`,
        element,
        text: normalizeText(element.textContent ?? ""),
        paragraph: planParagraph(element),
      };
      this.blocks.push(block);
      this.byElement.set(element, block);
      added++;
    }
    return added;
  }

  private items(): SyncItem[] {
    return this.blocks.map(({ id, paragraph: { markup } }) => ({
      id,
      text: markup.plain,
      input: markup.input === markup.plain ? undefined : markup.input,
    }));
  }

  /**
   * New paragraphs, and paragraphs whose text is no longer what we left there (our translation, or the original
   * we sent) or whose inner element we write into was replaced: the site rewrote or reused them, so they are taken
   * again as new text.
   */
  private rescan() {
    let changed = false;
    for (const block of this.blocks) {
      if (!block.element.isConnected) {
        changed = true;
        continue;
      }
      if (this.isStale(block)) {
        this.byElement.delete(block.element);
        block.original = undefined;
        block.result = undefined;
        block.shown = undefined;
        block.element.removeAttribute("data-plamonic-translated");
        changed = true;
      }
    }
    this.blocks = this.blocks.filter((block) => block.element.isConnected && this.byElement.get(block.element) === block);
    if (this.addBlocks(this.finder.find(document.body)) > 0) changed = true;
    this.mutations?.takeRecords();
    if (changed) this.sync?.setItems(this.items());
    this.measure();
  }

  private expectedText(block: Block) {
    return block.shown ?? block.text;
  }

  /**
   * The site changed the paragraph since we planned it: its text is not what we left there, or the element we
   * write into is no longer in it (replaced by one with the same text).
   */
  private isStale(block: Block) {
    const target = block.paragraph.target;
    if (target !== block.element && !block.element.contains(target)) return true;
    return normalizeText(block.element.textContent ?? "") !== this.expectedText(block);
  }

  /**
   * Which paragraphs are on screen, or within a quarter of a screen of it (so the next ones are ready when they
   * scroll in), by their boxes. Measured, not observed: an IntersectionObserver missed most of Reddit's comments.
   */
  private measure() {
    const margin = innerHeight * 0.25;
    this.visible.clear();
    for (const block of this.blocks) {
      const rect = block.element.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) continue;
      if (rect.bottom >= -margin && rect.top <= innerHeight + margin) this.visible.set(block.element, rect.top + scrollY);
    }
    this.updateFocus();
  }

  /** After scrolling settles a little (at most a few times a second while it goes on). */
  private scheduleMeasure() {
    if (this.measureTimer !== undefined) return;
    this.measureTimer = setTimeout(() => {
      this.measureTimer = undefined;
      this.measure();
    }, 200);
  }

  /** What is on screen, top to bottom (a sticky header first, then the article where it is scrolled to). */
  private updateFocus() {
    const onScreen = this.blocks
      .filter((block) => this.visible.has(block.element))
      .sort((a, b) => this.visible.get(a.element)! - this.visible.get(b.element)!)
      .slice(0, MAX_VISIBLE)
      .map((block) => block.id);
    this.sync?.setVisible(onScreen);
  }

  // MARK: Showing translations

  private apply() {
    const sync = this.sync;
    if (!sync) return;
    if (!this.warned && (sync.status.state === "unreachable" || sync.status.state === "disabled")) {
      this.warned = true;
      showToast(
        sync.status.state === "unreachable" ? "Plamonic が起動していません。起動すると翻訳を始めます。" : "Plamonic で拡張機能への翻訳がオフです。",
        "warn",
      );
    }
    const written: Element[] = [];
    const updates: (() => void)[] = [];
    for (const block of this.blocks) {
      const result = sync.results.get(block.id);
      if (!result?.text || (result.state !== "draft" && result.state !== "final")) continue;
      if (block.result === result.text || !block.element.isConnected) continue;
      // The site put other text here since: it is translated anew with the next scan, not given this one.
      if (this.isStale(block)) {
        this.scheduleRescan();
        continue;
      }
      const text = result.text;
      const state = result.state;
      written.push(block.element);
      updates.push(() => {
        const target = block.paragraph.target;
        block.original ??= [...target.childNodes];
        const rendered = renderTranslation(block.paragraph, text);
        block.result = text;
        block.shown = rendered.text;
        target.replaceChildren(rendered.nodes);
        block.element.setAttribute("data-plamonic-translated", state);
      });
    }
    if (updates.length) {
      this.write(written, () => updates.forEach((update) => update()));
      // Translations change the paragraphs' heights.
      this.scheduleMeasure();
    }
  }

  private restore(block: Block) {
    if (!block.original || !block.element.isConnected) return;
    // Only where our translation is still what the element shows: elsewhere the site has replaced it.
    if (!this.isStale(block)) {
      block.paragraph.target.replaceChildren(...block.original);
    }
    block.element.removeAttribute("data-plamonic-translated");
    block.original = undefined;
    block.result = undefined;
    block.shown = undefined;
  }

  private *translatedElements(): Iterable<Element> {
    for (const block of this.blocks) if (block.shown !== undefined) yield block.element;
  }

  private translatedCount() {
    return this.blocks.filter((block) => block.shown !== undefined).length;
  }
}
