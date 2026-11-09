/**
 * Runs in YouTube's own JavaScript world (not the content script's), where the player and its requests are.
 *
 * - Reports every caption request the player makes. Only the player can attach the proof-of-origin token
 *   (`pot=`) that the caption server now requires; the content script reuses the reported URL for other tracks
 *   of the same video.
 * - Answers the content script's questions about the player (the caption tracks of the current video).
 *
 * It talks to the content script with window.postMessage. It may be injected twice (a script tag and the
 * scripting API); the second copy does nothing.
 */
import { HOOK_SOURCE, CONTENT_SOURCE, type HookMessage, type ContentToHook } from "./hook-messages";

declare global {
  interface Window {
    __plamonicHook?: boolean;
  }
}

interface Player extends HTMLElement {
  getPlayerResponse?(): {
    videoDetails?: { videoId?: string; title?: string; author?: string };
    captions?: { playerCaptionsTracklistRenderer?: { captionTracks?: RawTrack[] } };
  };
  getVideoData?(): { video_id?: string };
}

interface RawTrack {
  languageCode: string;
  kind?: string;
  vssId?: string;
  name?: { simpleText?: string; runs?: { text: string }[] };
}

(() => {
  if (window.__plamonicHook) return;
  window.__plamonicHook = true;

  const post = (message: HookMessage) => window.postMessage({ source: HOOK_SOURCE, ...message }, location.origin);

  const report = (url: string) => {
    if (!url.includes("/api/timedtext")) return;
    try {
      const absolute = new URL(url, location.href);
      post({
        kind: "timedtext",
        url: absolute.href,
        videoId: absolute.searchParams.get("v") ?? "",
        hasPot: absolute.searchParams.has("pot"),
      });
    } catch {}
  };

  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (this: XMLHttpRequest, method: string, url: string | URL) {
    report(String(url));
    // eslint-disable-next-line prefer-rest-params
    return open.apply(this, arguments as unknown as Parameters<typeof open>);
  } as typeof open;

  const originalFetch = window.fetch;
  window.fetch = function (input: RequestInfo | URL, init?: RequestInit) {
    try {
      report(typeof input === "string" ? input : input instanceof URL ? input.href : input.url);
    } catch {}
    return originalFetch.call(this, input, init);
  };

  const player = () => document.getElementById("movie_player") as Player | null;

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== CONTENT_SOURCE) return;
    const message = event.data as ContentToHook;
    if (message.kind === "ping") {
      post({ kind: "ready" });
    } else if (message.kind === "get-tracks") {
      const response = player()?.getPlayerResponse?.();
      const tracks = response?.captions?.playerCaptionsTracklistRenderer?.captionTracks ?? [];
      post({
        kind: "tracks",
        requestId: message.requestId,
        videoId: response?.videoDetails?.videoId ?? player()?.getVideoData?.()?.video_id ?? "",
        title: response?.videoDetails?.title ?? "",
        author: response?.videoDetails?.author ?? "",
        tracks: tracks.map((track) => ({
          languageCode: track.languageCode,
          kind: track.kind,
          vssId: track.vssId,
          name: track.name?.simpleText ?? track.name?.runs?.map((run) => run.text).join("") ?? track.languageCode,
        })),
      });
    }
  });

  post({ kind: "ready" });
})();
