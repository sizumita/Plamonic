import type { CaptionTrack } from "./hook-messages";

/**
 * The track to translate: captions in the language spoken in the video. The automatic captions tell which
 * language that is; captions written by people in that language are preferred over them. Without automatic
 * captions, the first track not already in the target language.
 */
export function chooseSourceTrack(tracks: CaptionTrack[], targetLanguage: string): CaptionTrack | undefined {
  const automatic = tracks.find((track) => track.kind === "asr");
  if (automatic) {
    const spoken = base(automatic.languageCode);
    return tracks.find((track) => track.kind !== "asr" && base(track.languageCode) === spoken) ?? automatic;
  }
  const target = base(targetLanguage);
  return tracks.find((track) => base(track.languageCode) !== target) ?? tracks[0];
}

/** "en-US" → "en", "zh-Hant" → "zh", "ja(easy)" → "ja". */
export function base(language: string): string {
  return language.toLowerCase().split(/[-_(]/)[0] ?? language;
}

/** The caption URL for `track`, made from a URL the player requested (it carries the player's token). */
export function trackURL(playerURL: string, track: CaptionTrack): string {
  const url = new URL(playerURL);
  url.searchParams.set("lang", track.languageCode);
  if (track.kind) url.searchParams.set("kind", track.kind);
  else url.searchParams.delete("kind");
  url.searchParams.delete("tlang");
  url.searchParams.set("fmt", "json3");
  return url.href;
}
