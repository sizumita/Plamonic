import { isSkipped } from "./blocks";
import { collapse, decode, encode, isVerbatim, type Markup, type MarkupRun } from "./markup";

/**
 * A paragraph's structure, kept through translation: links, inline formatting, inline code, icons and images stay
 * where they were around the translated text (markup.ts says how they travel through the model).
 *
 * The translation replaces the children of `target`: the paragraph, or the one element inside it that holds all its
 * text (a heading that is one link: the link stays the page's own element, with its event handlers). Below it, the
 * text is cut into runs by the links and formatting elements around it. A run inside one is translated as a marked
 * piece and wrapped again in a copy of those elements (with their attributes: href, class, style). Code and links
 * whose text is a URL or an @mention are copied whole where their text appears in the translation. Line breaks
 * (`<br>`) travel as "\n". Other elements without text (icons, images) are copied next to the run they were next to.
 */
export interface Paragraph {
  target: Element;
  markup: Markup;
  runs: Run[];
  atoms: Atom[];
}

interface Run {
  /** Links and formatting elements around the run, outermost first (below `target`). */
  chain: Element[];
  /** An element copied whole (code, a link whose text is a URL or an @mention). */
  unit?: Element;
  /** A `<br>`: travels as a line break, and each line break of the translation becomes one again. */
  lineBreak?: boolean;
}

/** An element without text. */
interface Atom {
  element: Element;
  chain: Element[];
  /** The run it goes with, and on which side; none = before all text (`before`) or after it. */
  run?: number;
  before: boolean;
}

/** Inline elements that mean something around their text, so the translation is wrapped in them again. */
const FORMATTING = new Set([
  "A", "ABBR", "B", "BDI", "BDO", "BIG", "CITE", "DEL", "DFN", "EM", "FONT", "I", "INS", "MARK", "Q", "S", "SMALL",
  "STRIKE", "STRONG", "SUB", "SUP", "TIME", "U", "VAR",
]);

/** Skipped elements whose text is never sent; they stay in the paragraph like an image. */
const NOT_TEXT = new Set([
  "STYLE", "SVG", "MATH", "CANVAS", "VIDEO", "AUDIO", "IFRAME", "OBJECT", "PRE", "TEXTAREA", "SELECT", "INPUT",
]);

/** Never copied (a copy of a script must not run again). */
const DROPPED = new Set(["SCRIPT", "NOSCRIPT", "TEMPLATE"]);

/** Skipped text longer than this (or on several lines) is kept like an image, not sent. */
const MAX_UNIT = 200;

export function planParagraph(block: Element): Paragraph {
  const target = innermostHolder(block);
  const runs: Run[] = [];
  const texts: MarkupRun[] = [];
  const atoms: Atom[] = [];

  const addText = (text: string, chain: Element[]) => {
    const last = runs.length - 1;
    if (last >= 0 && !runs[last]!.unit && !runs[last]!.lineBreak && sameChain(runs[last]!.chain, chain)) {
      texts[last]!.text += text;
      return;
    }
    runs.push({ chain });
    texts.push({ text, styled: chain.length > 0, verbatim: false });
  };

  const walk = (parent: Element, chain: Element[]) => {
    for (const node of parent.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        addText((node as Text).data, chain);
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      const element = node as Element;
      const tag = element.tagName.toUpperCase();
      if (DROPPED.has(tag)) continue;
      if (tag === "BR") {
        runs.push({ chain, lineBreak: true });
        texts.push({ text: "", styled: false, verbatim: false, lineBreak: true });
        continue;
      }
      const text = element.textContent ?? "";
      if (!/\S/.test(text) && !NOT_TEXT.has(tag) && element.childElementCount === 0) {
        // Only whitespace (`Hello<span> </span>world`): it separates words, so it stays in the text.
        addText(text, chain);
      } else if (!/\S/.test(text) || NOT_TEXT.has(tag) || (isSkipped(element) && !isUnitText(text))) {
        atoms.push({ element, chain, run: runs.length - 1, before: false });
        // An icon with spaces around it inside: the words on both sides stay apart.
        if (/\s/.test(text)) addText(" ", chain);
      } else if (isSkipped(element) || (isLink(element) && isVerbatim(collapse(text)))) {
        runs.push({ chain, unit: element });
        texts.push({ text, styled: chain.length > 0, verbatim: true });
      } else {
        walk(element, FORMATTING.has(tag) || isLink(element) ? [...chain, element] : chain);
      }
    }
  };
  walk(target, []);

  for (const atom of atoms) placeAtom(atom, runs, texts);
  return { target, markup: encode(texts), runs, atoms };
}

/** The page's paragraph nodes for a translation of `paragraph.markup.input`, and their text. */
export function renderTranslation(paragraph: Paragraph, output: string): { nodes: DocumentFragment; text: string } {
  const pieces = decode(output, paragraph.markup);
  const fragment = document.createDocumentFragment();
  const copied = new Set<Element>();
  /** The copies of the elements of the chain written last, outermost first. */
  const open: { original: Element; copy: Element }[] = [];

  const write = (node: Node, chain: Element[]) => {
    let common = 0;
    while (common < open.length && common < chain.length && open[common]!.original === chain[common]) common++;
    open.length = common;
    for (let index = common; index < chain.length; index++) {
      const original = chain[index]!;
      const copy = original.cloneNode(false) as Element;
      // A second copy of the same element (split by the word order) must not repeat its id.
      if (copied.has(original)) copy.removeAttribute("id");
      copied.add(original);
      (open[index - 1]?.copy ?? fragment).append(copy);
      open.push({ original, copy });
    }
    (open[open.length - 1]?.copy ?? fragment).append(node);
  };
  const writeAtom = (atom: Atom) => write(atom.element.cloneNode(true), atom.chain);

  const placed = new Set(pieces.flatMap((piece) => (piece.run === undefined ? [] : [piece.run])));
  const loose = paragraph.atoms.filter((atom) => atom.run === undefined || !placed.has(atom.run));
  loose.filter((atom) => atom.before).forEach(writeAtom);
  pieces.forEach((piece, position) => {
    if (piece.run === undefined && piece.text.includes("\n")) {
      piece.text.split("\n").forEach((line, index) => {
        if (index > 0) write(document.createElement("br"), []);
        if (line) write(document.createTextNode(line), []);
      });
      return;
    }
    if (piece.run === undefined) {
      // Spaces between two pieces in the same element stay inside it (no gap in a link's underline).
      const chain = /\S/.test(piece.text)
        ? []
        : commonChain(chainOf(paragraph, pieces[position - 1]), chainOf(paragraph, pieces[position + 1]));
      write(document.createTextNode(piece.text), chain);
      return;
    }
    const run = paragraph.runs[piece.run]!;
    const own = paragraph.atoms.filter((atom) => atom.run === piece.run);
    own.filter((atom) => atom.before).forEach(writeAtom);
    write(run.unit ? run.unit.cloneNode(true) : document.createTextNode(piece.text), run.chain);
    own.filter((atom) => !atom.before).forEach(writeAtom);
  });
  loose.filter((atom) => !atom.before).forEach(writeAtom);
  return { nodes: fragment, text: collapse(fragment.textContent ?? "") };
}

/**
 * Which run an element without text goes with. Inside a link or formatting element: the run in the same element
 * (an icon in a link). Otherwise after the run before it when that is a link, formatting or code (an emoji after a
 * mention); before all text when it came first (an avatar); else after all text (the order of the
 * sentences around it may change).
 */
function placeAtom(atom: Atom, runs: Run[], texts: MarkupRun[]) {
  const previous = atom.run ?? -1;
  atom.run = undefined;
  const hasText = (index: number) => /\S/.test(texts[index]!.text);
  if (atom.chain.length > 0) {
    const holder = atom.chain[atom.chain.length - 1]!;
    const inHolder = (index: number) => runs[index]!.chain.includes(holder) && hasText(index);
    for (let index = previous + 1; index < runs.length; index++) {
      if (inHolder(index)) {
        atom.run = index;
        atom.before = true;
        return;
      }
    }
    for (let index = previous; index >= 0; index--) {
      if (inHolder(index)) {
        atom.run = index;
        return;
      }
    }
  }
  let before = previous;
  while (before >= 0 && !hasText(before)) before--;
  if (before < 0) {
    atom.before = true;
  } else if (runs[before]!.chain.length > 0 || runs[before]!.unit) {
    atom.run = before;
  }
}

/**
 * Goes down while one child element holds all the text (and the rest is whitespace or has no text), so that
 * translation writes into the page's own element. Not into skipped elements or ones copied whole.
 */
function innermostHolder(block: Element): Element {
  let target = block;
  for (;;) {
    let holder: Element | undefined;
    let single = true;
    for (const node of target.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) {
        if (/\S/.test((node as Text).data)) single = false;
      } else if (node.nodeType === Node.ELEMENT_NODE && /\S/.test(node.textContent ?? "")) {
        if (holder) single = false;
        holder = node as Element;
      }
      if (!single) break;
    }
    if (!single || !holder || isSkipped(holder) || DROPPED.has(holder.tagName.toUpperCase())) return target;
    target = holder;
  }
}

function isLink(element: Element): boolean {
  return element.hasAttribute("href") || element.getAttribute("role") === "link";
}

function isUnitText(text: string): boolean {
  const trimmed = text.trim();
  return trimmed.length <= MAX_UNIT && !trimmed.includes("\n");
}

function sameChain(a: Element[], b: Element[]): boolean {
  return a.length === b.length && a.every((element, index) => element === b[index]);
}

function chainOf(paragraph: Paragraph, piece: { run?: number } | undefined): Element[] {
  return piece?.run === undefined ? [] : paragraph.runs[piece.run]!.chain;
}

function commonChain(a: Element[], b: Element[]): Element[] {
  let length = 0;
  while (length < a.length && length < b.length && a[length] === b[length]) length++;
  return a.slice(0, length);
}
