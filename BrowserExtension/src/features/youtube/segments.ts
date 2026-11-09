import type { ParsedTrack, Piece } from "./json3";

/**
 * Turns caption pieces into the units that are translated and shown: sentences where the captions have
 * punctuation, and pause-delimited phrases where they do not (automatic captions). A caption written as two
 * halves of a sentence is translated as one sentence and shown for the time of both halves.
 */
export interface Segment {
  /** Stable for the same track: derived from the start time. */
  id: string;
  /** Milliseconds. */
  start: number;
  end: number;
  /** Until when the segment stays on screen: a little after it ends, unless the next one starts. */
  displayEnd: number;
  text: string;
}

interface Limits {
  /** A silence this long between two pieces ends a segment, once it has `minChars` characters. */
  pauseMs: number;
  minChars: number;
  /** A silence this long ends a segment however short. */
  longPauseMs: number;
  maxChars: number;
  maxMs: number;
  /** Without punctuation: past this many characters, a shorter pause also ends a segment. */
  softChars: number;
  softPauseMs: number;
}

const PUNCTUATED: Limits = {
  pauseMs: 1500, minChars: 0, longPauseMs: 1500, maxChars: 220, maxMs: 15000, softChars: 120, softPauseMs: 700,
};
const UNPUNCTUATED: Limits = {
  pauseMs: 600, minChars: 15, longPauseMs: 2500, maxChars: 100, maxMs: 7000, softChars: 45, softPauseMs: 250,
};
/** How long a segment stays after it ends when nothing follows right away. */
const HOLD_MS = 800;

const SENTENCE_END = /[.!?。！？…]["')\]」』”’]*$/;

export function buildSegments(track: ParsedTrack): Segment[] {
  const pieces = track.pieces;
  if (pieces.length === 0) return [];
  const limits = isPunctuated(pieces) ? PUNCTUATED : UNPUNCTUATED;
  const groups: Piece[][] = [];
  let current: Piece[] = [];
  let length = 0;

  for (const piece of pieces) {
    const last = current[current.length - 1];
    if (last) {
      const pause = piece.start - last.end;
      const duration = piece.end - current[0]!.start;
      const breakHere =
        pause >= limits.longPauseMs ||
        (pause >= limits.pauseMs && length >= limits.minChars) ||
        (length >= limits.softChars && pause >= limits.softPauseMs) ||
        length + piece.text.length > limits.maxChars ||
        duration > limits.maxMs;
      if (breakHere) {
        groups.push(current);
        current = [];
        length = 0;
      }
    }
    current.push(piece);
    length += piece.text.length + 1;
    if (limits === PUNCTUATED && SENTENCE_END.test(piece.text) && length >= 8) {
      groups.push(current);
      current = [];
      length = 0;
    }
  }
  if (current.length) groups.push(current);

  const used = new Set<string>();
  const segments = groups.map((group) => {
    const start = group[0]!.start;
    let id = `t${start}`;
    for (let n = 1; used.has(id); n++) id = `t${start}.${n}`;
    used.add(id);
    return {
      id,
      start,
      end: Math.max(...group.map((piece) => piece.end)),
      displayEnd: 0,
      text: group.reduce((text, piece) => join(text, piece.text), ""),
    };
  });
  segments.forEach((segment, index) => {
    const next = segments[index + 1];
    const end = segment.end + HOLD_MS;
    segment.displayEnd = next ? Math.max(segment.end, Math.min(end, next.start)) : end;
  });
  return segments;
}

/** Index of the segment on screen at `time` (ms), or -1. */
export function segmentAt(segments: Segment[], time: number): number {
  let low = 0;
  let high = segments.length - 1;
  let found = -1;
  while (low <= high) {
    const middle = (low + high) >> 1;
    if (segments[middle]!.start <= time) {
      found = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return found >= 0 && time < segments[found]!.displayEnd ? found : -1;
}

/** Index of the segment on screen at `time`, else the next one to come, else -1. */
export function segmentAtOrAfter(segments: Segment[], time: number): number {
  const at = segmentAt(segments, time);
  if (at >= 0) return at;
  const next = segments.findIndex((segment) => segment.start > time);
  return next;
}

/** Whether the captions mark sentence ends: then sentences, otherwise pauses, make the segments. */
function isPunctuated(pieces: Piece[]): boolean {
  const ends = pieces.filter((piece) => SENTENCE_END.test(piece.text)).length;
  return ends / pieces.length >= 0.05;
}

/** Joins with a space, except next to CJK text, which is written without spaces. */
function join(text: string, next: string): string {
  if (!text) return next;
  const cjk = /[　-ヿ㐀-鿿가-힯＀-￯]/;
  return cjk.test(text.slice(-1)) || cjk.test(next.charAt(0)) ? text + next : `${text} ${next}`;
}
