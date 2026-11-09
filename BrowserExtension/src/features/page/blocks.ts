/**
 * The paragraphs of a page. Every piece of text belongs to the nearest element around it that the browser lays out
 * as a block (by its computed `display`): links, spans and custom elements shown inline are part of the sentence
 * around them, so a comment that starts with an @mention link is one paragraph. A block that holds other blocks
 * is left out (translating it would replace them), its loose text with it. Code, form fields, editable areas and
 * parts marked not to translate are left alone, as is anything of ours.
 */
const SKIPPED_TAGS = new Set([
  "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "CODE", "PRE", "KBD", "SAMP", "TEXTAREA", "INPUT", "SELECT", "OPTION",
  "SVG", "MATH", "CANVAS", "VIDEO", "AUDIO", "IFRAME", "OBJECT", "HEAD", "TITLE",
]);

/**
 * Parts that must survive inside a paragraph: translating replaces the paragraph's children with copies, so a
 * paragraph holding one of these is left as it is. (Inline code is not among them: it is part of ordinary
 * sentences, and the translation keeps a copy of it where its text appears, rich-text.ts.)
 */
const PROTECTED_INSIDE =
  'input, textarea, select, [translate="no"], .notranslate, [contenteditable]:not([contenteditable="false"])';

/** At most this many paragraphs per page. */
export const MAX_BLOCKS = 3000;

export function normalizeText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Whether `element` and everything inside it is to be left as it is. */
export function isSkipped(element: Element): boolean {
  if (SKIPPED_TAGS.has(element.tagName.toUpperCase())) return true;
  if (element.tagName.toLowerCase().startsWith("plamonic-")) return true;
  if (element.getAttribute("translate") === "no" || element.classList.contains("notranslate")) return true;
  if ((element as HTMLElement).isContentEditable) return true;
  return element.getAttribute("aria-hidden") === "true";
}

/**
 * Finds paragraphs, remembering per element whether it is skipped and where its block is, so that a rescan of a
 * growing page (new replies, infinite scroll) costs little.
 */
export class BlockFinder {
  private blockOf = new WeakMap<Element, Element | null>();
  private display = new WeakMap<Element, string>();

  /**
   * Where to look, from the site's settings: only inside `include` (an included element counts as a paragraph of
   * its own even when shown inline), and never inside `exclude`. Empty `include` = the whole page.
   */
  constructor(
    private readonly include = "",
    private readonly exclude = "",
  ) {}

  /** The paragraph elements under `root`, in document order. */
  find(root: Element): Element[] {
    const blocks: Element[] = [];
    const seen = new Set<Element>();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent || !/\S/.test(node.textContent)) continue;
      const parent = node.parentElement;
      const block = parent ? this.block(parent) : null;
      if (!block || seen.has(block) || !this.isWanted(block)) continue;
      seen.add(block);
      blocks.push(block);
    }
    // A block inside another one: the outer one cannot be replaced without losing it.
    const containers = new Set<Element>();
    for (const block of blocks) {
      for (let parent = block.parentElement; parent; parent = parent.parentElement) {
        if (containers.has(parent)) break;
        if (seen.has(parent)) containers.add(parent);
      }
    }
    return blocks
      .filter((block) => !containers.has(block) && normalizeText(block.textContent ?? "").length >= 2)
      .slice(0, MAX_BLOCKS);
  }

  /** The nearest block-level element around `element` (itself included), or null when the text is skipped. */
  private block(element: Element): Element | null {
    const known = this.blockOf.get(element);
    if (known !== undefined) return known;
    let result: Element | null;
    if (isSkipped(element)) {
      result = null;
    } else if (element === document.body || element === document.documentElement) {
      result = null;
    } else if (!this.isInline(element) || (this.include && element.matches(this.include))) {
      // A block, unless something around it is skipped.
      const parent = element.parentElement;
      result = parent && this.isInsideSkipped(parent) ? null : element;
    } else {
      result = element.parentElement ? this.block(element.parentElement) : null;
    }
    this.blockOf.set(element, result);
    return result;
  }

  private isWanted(block: Element): boolean {
    if (this.exclude && (block.closest(this.exclude) || block.querySelector(this.exclude))) return false;
    if (block.querySelector(PROTECTED_INSIDE)) return false;
    return !this.include || block.closest(this.include) !== null;
  }

  private isInsideSkipped(element: Element): boolean {
    for (let current: Element | null = element; current; current = current.parentElement) {
      if (isSkipped(current)) return true;
    }
    return false;
  }

  /** Laid out as part of the line (`inline`, or `contents`, which has no box of its own). */
  private isInline(element: Element): boolean {
    let display = this.display.get(element);
    if (display === undefined) {
      display = getComputedStyle(element).display;
      this.display.set(element, display);
    }
    return display === "inline" || display === "contents";
  }
}
