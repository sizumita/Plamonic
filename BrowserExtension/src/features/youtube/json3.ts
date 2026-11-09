/**
 * YouTube's caption format ("json3"): events with a start and duration, each with text pieces (segs).
 *
 * - Captions written by people: one event per caption, usually one piece.
 * - Automatic captions in Chrome: rolling two-line windows whose pieces are single words with offsets
 *   (`tOffsetMs`), separated by events that only append a newline (`aAppend`).
 * - Automatic captions in Safari came as whole lines without word offsets.
 *
 * All of them become a time-ordered list of pieces; a piece is a word or a whole line.
 */
export interface Json3 {
  events?: Json3Event[];
}

interface Json3Event {
  tStartMs?: number;
  dDurationMs?: number;
  aAppend?: number;
  segs?: { utf8?: string; tOffsetMs?: number }[];
}

export interface Piece {
  /** Milliseconds from the start of the video. */
  start: number;
  end: number;
  text: string;
}

export interface ParsedTrack {
  pieces: Piece[];
  /** Pieces are single words (automatic captions with word timing). */
  wordLevel: boolean;
}

/** Longest a single word is assumed to last; longer silences after it count as pauses. */
const MAX_WORD_MS = 800;

export function parseJson3(data: Json3): ParsedTrack {
  const pieces: Piece[] = [];
  let wordLevel = false;
  for (const event of data.events ?? []) {
    if (event.aAppend || !event.segs?.length) continue;
    const start = event.tStartMs ?? 0;
    const end = start + (event.dDurationMs ?? 0);
    const timed = event.segs.length > 1 && event.segs.some((seg) => seg.tOffsetMs !== undefined);
    if (timed) {
      wordLevel = true;
      event.segs.forEach((seg, index) => {
        const text = clean(seg.utf8);
        if (!text) return;
        const wordStart = start + (seg.tOffsetMs ?? 0);
        const next = event.segs![index + 1];
        const nextStart = next ? start + (next.tOffsetMs ?? 0) : end;
        pieces.push({ start: wordStart, end: Math.min(nextStart, wordStart + MAX_WORD_MS, end), text });
      });
    } else {
      const text = clean(event.segs.map((seg) => seg.utf8 ?? "").join(""));
      if (text) pieces.push({ start, end, text });
    }
  }
  pieces.sort((a, b) => a.start - b.start);
  return { pieces, wordLevel };
}

function clean(text: string | undefined): string {
  return (text ?? "").replace(/\s+/g, " ").trim();
}
