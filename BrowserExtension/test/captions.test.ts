import assert from "node:assert/strict";
import { test } from "node:test";
import { parseJson3 } from "../src/features/youtube/json3";
import { buildSegments, segmentAt, segmentAtOrAfter } from "../src/features/youtube/segments";
import { base, chooseSourceTrack, trackURL } from "../src/features/youtube/tracks";

// Shapes as YouTube sends them (texts made up).

const manual = {
  events: [
    { tStartMs: 0, dDurationMs: 4000, segs: [{ utf8: "Translator: Someone\nReviewer: Someone Else" }] },
    { tStartMs: 12000, dDurationMs: 1400, segs: [{ utf8: "So in school," }] },
    { tStartMs: 13500, dDurationMs: 1500, segs: [{ utf8: "I studied history." }] },
    { tStartMs: 15100, dDurationMs: 2400, segs: [{ utf8: "That meant writing\na lot of essays." }] },
    { tStartMs: 30000, dDurationMs: 2000, segs: [{ utf8: "(Laughter)" }] },
  ],
};

const automaticWords = {
  events: [
    { tStartMs: 0, dDurationMs: 800000, id: 1, wpWinPosId: 1, wsWinStyleId: 1 },
    { tStartMs: 12500, dDurationMs: 4400, wWinId: 1, segs: [{ utf8: "so" }, { utf8: " in", tOffsetMs: 200 }] },
    { tStartMs: 14300, dDurationMs: 2600, wWinId: 1, aAppend: 1, segs: [{ utf8: "\n" }] },
    {
      tStartMs: 14300,
      dDurationMs: 5200,
      wWinId: 1,
      segs: [
        { utf8: "school" },
        { utf8: " I", tOffsetMs: 300 },
        { utf8: " studied", tOffsetMs: 400 },
        { utf8: " history", tOffsetMs: 700 },
      ],
    },
    // A pause of more than a second, then the next phrase.
    { tStartMs: 17000, dDurationMs: 2600, wWinId: 1, aAppend: 1, segs: [{ utf8: "\n" }] },
    { tStartMs: 17200, dDurationMs: 3000, wWinId: 1, segs: [{ utf8: "which" }, { utf8: " meant", tOffsetMs: 200 }, { utf8: " essays", tOffsetMs: 500 }] },
  ],
};

test("captions written by people become one piece per caption, with line breaks as spaces", () => {
  const track = parseJson3(manual);
  assert.equal(track.wordLevel, false);
  assert.deepEqual(track.pieces.map((piece) => piece.text).slice(0, 2), [
    "Translator: Someone Reviewer: Someone Else",
    "So in school,",
  ]);
  assert.deepEqual(track.pieces[1], { start: 12000, end: 13400, text: "So in school," });
});

test("automatic captions become timed words, skipping the newline-only events", () => {
  const track = parseJson3(automaticWords);
  assert.equal(track.wordLevel, true);
  assert.deepEqual(track.pieces.map((piece) => piece.text), ["so", "in", "school", "I", "studied", "history", "which", "meant", "essays"]);
  assert.deepEqual(track.pieces[2], { start: 14300, end: 14600, text: "school" });
  // The last word of an event lasts at most 800 ms, so a following silence shows as a pause.
  assert.deepEqual(track.pieces[5], { start: 15000, end: 15800, text: "history" });
});

test("halves of a sentence are joined and shown for the time of both", () => {
  const segments = buildSegments(parseJson3(manual));
  assert.deepEqual(segments.map((segment) => segment.text), [
    "Translator: Someone Reviewer: Someone Else",
    "So in school, I studied history.",
    "That meant writing a lot of essays.",
    "(Laughter)",
  ]);
  const sentence = segments[1]!;
  assert.equal(sentence.start, 12000);
  assert.equal(sentence.end, 15000);
  // Shown until the next one starts (it starts 100 ms later).
  assert.equal(sentence.displayEnd, 15100);
  assert.equal(segments[2]!.displayEnd, 17500 + 800);
});

test("automatic captions without punctuation are split at pauses", () => {
  const segments = buildSegments(parseJson3(automaticWords));
  assert.deepEqual(segments.map((segment) => segment.text), ["so in school I studied history", "which meant essays"]);
});

test("ids are stable and unique", () => {
  const first = buildSegments(parseJson3(manual)).map((segment) => segment.id);
  const second = buildSegments(parseJson3(manual)).map((segment) => segment.id);
  assert.deepEqual(first, second);
  assert.equal(new Set(first).size, first.length);
});

test("Japanese text is joined without spaces", () => {
  const segments = buildSegments({
    wordLevel: false,
    pieces: [
      { start: 0, end: 1000, text: "今日は" },
      { start: 1100, end: 2000, text: "いい天気です。" },
    ],
  });
  assert.deepEqual(segments.map((segment) => segment.text), ["今日はいい天気です。"]);
});

test("the segment on screen, and the next one in a gap", () => {
  const segments = buildSegments(parseJson3(manual));
  assert.equal(segmentAt(segments, 12500), 1);
  assert.equal(segmentAt(segments, 20000), -1);
  assert.equal(segmentAtOrAfter(segments, 20000), 3);
  assert.equal(segmentAtOrAfter(segments, 60000), -1);
  assert.equal(segmentAt(segments, 100), 0);
});

test("the spoken language's written captions are preferred to automatic ones", () => {
  const tracks = [
    { languageCode: "ar", name: "Arabic" },
    { languageCode: "en", name: "English" },
    { languageCode: "en", kind: "asr", name: "English (auto)" },
    { languageCode: "ja", name: "Japanese" },
  ];
  assert.equal(chooseSourceTrack(tracks, "ja")?.name, "English");
  assert.equal(chooseSourceTrack([tracks[0]!, tracks[2]!], "ja")?.name, "English (auto)");
  // No automatic captions: the first track not in the target language.
  assert.equal(chooseSourceTrack([tracks[3]!, tracks[1]!], "ja")?.name, "English");
  assert.equal(chooseSourceTrack([], "ja"), undefined);
  assert.equal(base("pt-BR"), "pt");
  assert.equal(base("ja(easy)"), "ja");
});

test("a track's URL reuses the player's request with its token", () => {
  const player = "https://www.youtube.com/api/timedtext?v=abc&lang=ja&pot=TOKEN&fmt=srv3&tlang=fr&c=WEB";
  const url = new URL(trackURL(player, { languageCode: "en", kind: "asr", name: "" }));
  assert.equal(url.searchParams.get("pot"), "TOKEN");
  assert.equal(url.searchParams.get("lang"), "en");
  assert.equal(url.searchParams.get("kind"), "asr");
  assert.equal(url.searchParams.get("fmt"), "json3");
  assert.equal(url.searchParams.has("tlang"), false);
  const written = new URL(trackURL(url.href, { languageCode: "en", name: "" }));
  assert.equal(written.searchParams.has("kind"), false);
});
