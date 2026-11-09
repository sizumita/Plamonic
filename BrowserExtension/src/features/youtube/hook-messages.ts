/** window.postMessage between the page hook (YouTube's world) and the content script. */
export const HOOK_SOURCE = "plamonic-page";
export const CONTENT_SOURCE = "plamonic-content";

export interface CaptionTrack {
  languageCode: string;
  /** "asr" for automatic captions. */
  kind?: string;
  vssId?: string;
  name: string;
}

export type HookMessage =
  | { kind: "ready" }
  | { kind: "timedtext"; url: string; videoId: string; hasPot: boolean }
  | { kind: "tracks"; requestId: string; videoId: string; title: string; author: string; tracks: CaptionTrack[] };

export type HookRequest = { kind: "ping" } | { kind: "get-tracks"; requestId: string };

export type ContentToHook = { source: typeof CONTENT_SOURCE } & HookRequest;
