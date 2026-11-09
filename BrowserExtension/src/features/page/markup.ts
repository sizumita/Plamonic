/**
 * Carries a paragraph's links and inline formatting through translation, the way the app carries links on screen
 * (`TranslationLinks.swift`, DESIGN §6.1 「訳文の中のリンク」).
 *
 * A paragraph comes as runs: plain text, text inside a link or inline formatting ("styled"), and text that must
 * come back unchanged ("verbatim": code, URLs, @mentions). Styled text is sent wrapped as `[text](n)`: the model
 * translates it in place and keeps the marker, and the number survives word-order changes. Verbatim text is sent
 * as it is and found in the translation by its text (wrapping it made the model drop or alter some). When the
 * markers come back broken, all of them are removed and the styled runs are looked up as plain text.
 */

export interface MarkupRun {
  /** The run's text as on the page (whitespace not collapsed). */
  text: string;
  /** Inside a link or inline formatting. */
  styled: boolean;
  /** Must appear in the translation as it is (code, a URL-like link). */
  verbatim: boolean;
  /** A line break (`<br>`): sent as "\n", which the model keeps. `text` is ignored. */
  lineBreak?: boolean;
}

export interface Markup {
  /** The paragraph's text, whitespace collapsed. */
  plain: string;
  /** What the model translates: `plain` with markers around the styled runs. */
  input: string;
  /** Per run: its text (whitespace collapsed, trimmed) and how it travels. */
  runs: PlannedRun[];
}

export interface PlannedRun {
  text: string;
  styled: boolean;
  verbatim: boolean;
  /** Number of its `[text](n)` marker; undefined when it is sent unmarked. */
  id?: number;
}

/** A part of the translation: plain text, or the translation of run `run`. */
export interface Piece {
  text: string;
  run?: number;
}

/** Markers carry up to three digits. */
const MAX_ID = 999;

/** `[text](n)`, also with full-width brackets, parentheses or digits, or a space before the "(". */
const MARKER = /[[［]([^[\]［］\n]*)[\]］] ?[(（]([0-9０-９]{1,3})[)）]/g;
/** What is left of a marker whose "[" went missing. */
const STRAY_ID = /[\]］] ?[(（][0-9０-９]{1,3}[)）]/g;
/** A number in parentheses: left over when it is one that was sent and the source does not have it. */
const ORPHAN_ID = /[(（]([0-9０-９]{1,3})[)）]/g;
/** A list number of the source: up to three digits before ")" or "）". */
const LIST_NUMBER = /(?<![0-9０-９])([0-9０-９]{1,3})[)）]/g;

export function collapse(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Plans how a paragraph's runs are sent to the model. */
export function encode(runs: MarkupRun[]): Markup {
  const planned: PlannedRun[] = runs.map((run) => {
    const text = run.lineBreak ? "" : collapse(run.text);
    return { text, styled: run.styled, verbatim: run.verbatim };
  });
  const plain = join(runs, planned, () => undefined);

  // Numbers start above the source's own list numbers ("(1)", "（2）", "3)", "①"), so that a translation writing
  // one of them as "(n)" does not look like a leftover marker. Unmarked when the source already reads like markup.
  const firstID = Math.max(0, ...listNumbers(plain)) + 1;
  const markable = planned.filter((run) => isMarkable(run)).length;
  const canMark = markable > 0 && !test(MARKER, plain) && !test(STRAY_ID, plain) && firstID + markable - 1 <= MAX_ID;
  let next = firstID;
  if (canMark) for (const run of planned) if (isMarkable(run)) run.id = next++;
  const input = canMark ? join(runs, planned, (run) => (run.id === undefined ? undefined : `[${run.text}](${run.id})`)) : plain;
  return { plain, input, runs: planned };
}

function isMarkable(run: PlannedRun): boolean {
  return run.styled && !run.verbatim && run.text !== "" && !/[[\]［］]/.test(run.text);
}

/**
 * The runs' texts joined with whitespace collapsed, a run's text replaced by `wrap` when it gives one. Line breaks
 * between texts become "\n" (at most one blank line, as the app keeps them).
 */
function join(runs: MarkupRun[], planned: PlannedRun[], wrap: (run: PlannedRun) => string | undefined): string {
  let out = "";
  let space = false;
  let breaks = 0;
  runs.forEach((run, index) => {
    const plan = planned[index]!;
    if (run.lineBreak) {
      breaks++;
      return;
    }
    if (/^\s/.test(run.text)) space = true;
    if (plan.text === "") return;
    if (out !== "") out += breaks > 0 ? "\n".repeat(Math.min(breaks, 2)) : space ? " " : "";
    out += wrap(plan) ?? plan.text;
    space = /\s$/.test(run.text);
    breaks = 0;
  });
  return out;
}

/** Splits the model's output for `markup.input` into plain text and the runs' translations, in output order. */
export function decode(output: string, markup: Markup): Piece[] {
  const wanted = new Set(markup.runs.flatMap((run) => (run.id === undefined ? [] : [run.id])));
  const runOf = new Map(markup.runs.flatMap((run, index) => (run.id === undefined ? [] : [[run.id, index] as const])));
  let pieces: Piece[] = [];
  let broken = false;

  if (wanted.size > 0) {
    // Brackets the source does not have are left over from markers. Ones it has may be its own.
    const keepsOpen = /[[［]/.test(markup.plain);
    const keepsClose = /[\]］]/.test(markup.plain);
    const own = new Map<number, number>();
    for (const value of listNumbers(markup.plain)) own.set(value, (own.get(value) ?? 0) + 1);
    const clean = (text: string) => {
      let piece = text.replace(STRAY_ID, () => {
        broken = true;
        return "";
      });
      piece = piece.replace(ORPHAN_ID, (match, digits: string) => {
        const id = number(digits);
        if (!wanted.has(id)) return match;
        const count = own.get(id) ?? 0;
        if (count > 0) {
          own.set(id, count - 1);
          return match;
        }
        broken = true;
        return "";
      });
      const stripped = piece.replace(/[[［\]］]/g, (bracket) =>
        (bracket === "[" || bracket === "［" ? keepsOpen : keepsClose) ? bracket : "",
      );
      if (stripped !== piece) broken = true;
      if (stripped) pieces.push({ text: stripped });
    };

    const seen = new Set<number>();
    let cursor = 0;
    for (const match of output.matchAll(MARKER)) {
      clean(output.slice(cursor, match.index));
      const anchor = match[1]!;
      const id = number(match[2]!);
      const run = runOf.get(id);
      if (run !== undefined && !seen.has(id)) {
        seen.add(id);
        const [, lead = "", core = "", trail = ""] = /^(\s*)([\s\S]*?)(\s*)$/.exec(anchor) ?? [];
        if (lead) pieces.push({ text: lead });
        if (core) pieces.push({ text: core, run });
        if (trail) pieces.push({ text: trail });
      } else {
        broken = true; // a number that was not sent, or one used twice
        if (anchor) pieces.push({ text: anchor });
      }
      cursor = match.index + match[0].length;
    }
    clean(output.slice(cursor));
    if (seen.size !== wanted.size) broken = true;
    if (broken) pieces = pieces.map((piece) => ({ text: piece.text }));
  } else {
    pieces.push({ text: output });
  }
  pieces = mergePlain(pieces);

  // Verbatim runs, and styled ones whose marker was not sent or did not come back: by their own text (one the
  // model kept, such as a name). Repeated texts take their occurrences in order.
  markup.runs.forEach((run, index) => {
    if (!run.styled && !run.verbatim) return;
    if (run.text === "" || pieces.some((piece) => piece.run === index)) return;
    if (!run.verbatim && run.text.length < 2) return;
    for (let position = 0; position < pieces.length; position++) {
      const piece = pieces[position]!;
      if (piece.run !== undefined) continue;
      let found = find(piece.text, run.text, run.verbatim);
      // A verbatim run the model changed in case, width or spacing ("＠Alice", "README .md"): written back.
      if (!found && run.verbatim) found = looseFind(piece.text, run.text);
      if (!found) continue;
      const parts: Piece[] = [];
      if (found.start > 0) parts.push({ text: piece.text.slice(0, found.start) });
      parts.push({ text: run.text, run: index });
      if (found.end < piece.text.length) parts.push({ text: piece.text.slice(found.end) });
      pieces.splice(position, 1, ...parts);
      return;
    }
  });
  return pieces;
}

function mergePlain(pieces: Piece[]): Piece[] {
  const merged: Piece[] = [];
  for (const piece of pieces) {
    const last = merged[merged.length - 1];
    if (last && last.run === undefined && piece.run === undefined) last.text += piece.text;
    else merged.push({ ...piece });
  }
  return merged;
}

/**
 * Text that must come back unchanged: URLs, @mentions, #channels and issue numbers, file names, paths, e-mail
 * addresses and identifiers. Everything else is natural language the model translates.
 */
export function isVerbatim(text: string): boolean {
  if (text === "") return true;
  if ("@#＠＃".includes(text[0]!)) return true;
  if (!/\p{Alphabetic}/u.test(text)) return true;
  if (text.includes("://") || text.toLowerCase().startsWith("www.")) return true;
  if (/\s/.test(text) || /[^\x00-\x7F]/.test(text)) return false;
  if (/[./\\_:@$`~=<>{}[\]()]/.test(text)) return true;
  // camelCase and brand-like names ("GitHub", "iOS").
  return /\p{Lowercase}\p{Uppercase}/u.test(text);
}

// MARK: Search

/** The first occurrence of `needle`; verbatim text must not run into a longer word ("@bob" in "@bobby"). */
function find(text: string, needle: string, verbatim: boolean): { start: number; end: number } | undefined {
  for (let start = text.indexOf(needle); start >= 0; start = text.indexOf(needle, start + 1)) {
    const range = { start, end: start + needle.length };
    if (!verbatim || isWordBounded(text, range, needle)) return range;
  }
  return undefined;
}

/** The copy of `needle` that differs only in case, width or whitespace. */
function looseFind(text: string, needle: string): { start: number; end: number } | undefined {
  const target = fold(needle).map((unit) => unit.char).join("");
  const units = fold(text);
  const haystack = units.map((unit) => unit.char).join("");
  if (!target) return undefined;
  for (let index = haystack.indexOf(target); index >= 0; index = haystack.indexOf(target, index + 1)) {
    const range = { start: units[index]!.start, end: units[index + target.length - 1]!.end };
    if (isWordBounded(text, range, needle)) return range;
  }
  return undefined;
}

/** Case- and width-folded UTF-16 units without whitespace, each with the range of `text` it came from. */
function fold(text: string): { char: string; start: number; end: number }[] {
  const units: { char: string; start: number; end: number }[] = [];
  let offset = 0;
  for (const char of text) {
    const start = offset;
    offset += char.length;
    if (/\s/.test(char)) continue;
    const folded = char.normalize("NFKC").toLowerCase();
    for (let index = 0; index < folded.length; index++) units.push({ char: folded[index]!, start, end: offset });
  }
  return units;
}

/** When the text starts or ends with an ASCII letter or digit, its neighbors must not be ones ("@aliceさん" is fine). */
function isWordBounded(text: string, range: { start: number; end: number }, needle: string): boolean {
  const word = /[0-9A-Za-z_]/;
  if (word.test(needle[0] ?? "") && range.start > 0 && word.test(text[range.start - 1]!)) return false;
  if (word.test(needle[needle.length - 1] ?? "") && range.end < text.length && word.test(text[range.end]!)) return false;
  return true;
}

// MARK: Helpers

/** The values of the list numbers in `text`: a number before ")" or "）", and an enclosed number ("①", "❶"). */
function listNumbers(text: string): number[] {
  const numbers = [...text.matchAll(LIST_NUMBER)].map((match) => number(match[1]!));
  for (const char of text) {
    const code = char.codePointAt(0)!;
    const enclosed =
      (code >= 0x2460 && code <= 0x24ff) || (code >= 0x2776 && code <= 0x2793) || (code >= 0x3251 && code <= 0x325f) ||
      (code >= 0x32b1 && code <= 0x32bf);
    if (!enclosed) continue;
    const value = Number.parseInt(char.normalize("NFKC").replace(/\D/g, ""), 10);
    if (Number.isInteger(value) && value <= MAX_ID) numbers.push(value);
  }
  return numbers;
}

function number(digits: string): number {
  return Number.parseInt(digits.replace(/[０-９]/g, (digit) => String(digit.charCodeAt(0) - 0xff10)), 10);
}

function test(pattern: RegExp, text: string): boolean {
  return new RegExp(pattern.source).test(text);
}
