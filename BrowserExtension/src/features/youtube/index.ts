import type { PageAction } from "../../shared/actions";
import { BROWSER, ext } from "../../shared/api";
import { updateSettings, type Settings } from "../../shared/settings";
import { DocumentSync } from "../../content/document-sync";
import type { Feature, FeatureContext, FeatureInstance } from "../../content/feature";
import { CONTENT_SOURCE, HOOK_SOURCE, type CaptionTrack, type HookMessage, type HookRequest } from "./hook-messages";
import { parseJson3, type Json3 } from "./json3";
import { CaptionOverlay, ensurePlayerButton } from "./overlay";
import { buildSegments, segmentAt, segmentAtOrAfter, type Segment } from "./segments";
import { base, chooseSourceTrack, trackURL } from "./tracks";
import { CAPTIONS_VIEW, type CaptionsPhase, type CaptionsViewState } from "./view";

/**
 * YouTube captions: finds the captions of the video being watched, has the app translate them ahead of
 * playback, draws the translation over the video and gives the sidebar a transcript that follows playback.
 *
 * How the captions are found (docs/BROWSER_EXTENSION_NOTES.md): the caption server only answers requests that
 * carry the player's proof-of-origin token, so the page hook reports the player's own caption request, and the
 * same URL with another `lang`/`kind` fetches the track to translate. The player asks only while captions are
 * on, so captions are switched on (and YouTube's are hidden behind ours).
 */
export const youtubeCaptions: Feature = {
  id: "youtube-captions",
  activation: "auto",
  matches: (url) => url.hostname === "www.youtube.com",
  create: (context) => new YouTubeCaptions(context),
};

const videoID = (url: URL) => (url.pathname === "/watch" ? (url.searchParams.get("v") ?? undefined) : undefined);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

class YouTubeCaptions implements FeatureInstance {
  private readonly video = videoID(new URL(location.href));
  private phase: CaptionsPhase = "idle";
  private message: string | undefined;
  private title = "";
  private channel = "";
  private track: CaptionTrack | undefined;
  private segments: Segment[] = [];
  private sync: DocumentSync | undefined;
  private overlay = new CaptionOverlay();
  private activeIndex = -1;
  private stopped = false;
  private potURL: string | undefined;
  private potWaiters: ((url: string) => void)[] = [];
  private hookReady = false;
  private frame: number | undefined;
  private videoElement: HTMLVideoElement | undefined;
  private readonly onMessage = (event: MessageEvent) => this.hookMessage(event);
  private readonly onTime = () => this.updateTime();
  private buttonTimer: ReturnType<typeof setInterval> | undefined;
  /** The captions are being found and translated (they start only when shown, or for the sidebar). */
  private begun = false;
  /** We switched YouTube's captions on to get the player's token; switched back off if the video shows them. */
  private captionsSwitchedOn = false;

  constructor(private readonly context: FeatureContext) {}

  /**
   * Listens to the page hook at once (the player's own caption request, when captions are on, saves switching
   * them), but finds and translates the captions only when they are to be seen: over the video (the menu's 動画の
   * 字幕) or in the sidebar. With YouTube's own captions (the default) and no sidebar, the app does nothing.
   */
  start() {
    addEventListener("message", this.onMessage);
    if (!this.video) return;
    this.keepPlayerButton();
    // A sidebar left open from the previous video (the page moved on without loading) shows this one's at once.
    if (this.context.settings().captionOverlay !== "off" || this.context.hasSidebar()) this.begin();
  }

  private begin() {
    if (this.begun || !this.video || this.stopped) return;
    this.begun = true;
    this.setPhase("loading");
    void this.load().catch((error) => this.fail(String(error?.message ?? error)));
  }

  sidebarOpened() {
    this.begin();
  }

  stop() {
    this.stopped = true;
    clearInterval(this.buttonTimer);
    removeEventListener("message", this.onMessage);
    this.sync?.stop();
    this.overlay.detach();
    this.unwatchVideo();
  }

  /** Another video is another document: restart. The same video (a timestamp in the address) carries on. */
  urlChanged(url: URL) {
    return videoID(url) === this.video;
  }

  settingsChanged(settings: Settings) {
    this.overlay.setMode(this.overlayMode(settings));
    if (settings.captionOverlay !== "off") this.begin();
  }

  /** The toolbar menu: what the video shows. */
  actions(): PageAction[] {
    if (!this.video) return [];
    return [
      {
        id: "overlay",
        kind: "choice",
        label: "動画の字幕",
        value: this.context.settings().captionOverlay,
        options: [
          { value: "translation", label: "訳文" },
          { value: "both", label: "訳文＋原文" },
          { value: "off", label: "元の字幕" },
        ],
      },
    ];
  }

  perform(action: string, value?: string) {
    if (action === "overlay" && (value === "translation" || value === "both" || value === "off")) {
      void updateSettings({ captionOverlay: value });
    }
  }

  command(command: string, args: unknown) {
    if (command === "seek" && this.videoElement) {
      const time = (args as { time: number }).time;
      this.videoElement.currentTime = time / 1000;
      this.updateTime();
    } else if (command === "retry") {
      this.sync?.retry();
    }
  }

  /** Only video pages have something for the sidebar. */
  view(): CaptionsViewState | undefined {
    if (!this.video) return undefined;
    const sync = this.sync;
    return {
      kind: CAPTIONS_VIEW,
      phase: this.phase,
      message: this.message,
      videoId: this.video,
      title: this.title,
      channel: this.channel,
      track: this.track && { language: this.track.languageCode, name: this.track.name, automatic: this.track.kind === "asr" },
      bridge: sync ? { state: sync.status.state, message: "message" in sync.status ? sync.status.message : undefined } : { state: "connecting" },
      progress: sync?.progress,
      lines: this.segments.map((segment) => {
        const result = sync?.results.get(segment.id);
        return { id: segment.id, start: segment.start, text: segment.text, translation: result?.text, state: result?.state ?? "pending" };
      }),
      activeId: this.segments[this.activeIndex]?.id,
    };
  }

  // MARK: Loading

  private async load() {
    await this.ensureHook();
    const info = await this.tracksOfThisVideo();
    if (this.stopped) return;
    this.title = info.title;
    this.channel = info.author;
    if (info.tracks.length === 0) return this.setPhase("no-captions", "この動画には字幕がありません");

    // The target language of this page's site: YouTube may have its own in Plamonic's settings.
    const status = await this.context.bridge({ type: "hello", url: location.href });
    const target = status.ok && status.targetLanguage ? status.targetLanguage : "ja";
    const track = chooseSourceTrack(info.tracks, target)!;
    this.track = track;

    const playerURL = await this.playerCaptionURL();
    if (this.stopped) return;
    this.restoreCaptions();
    const response = await fetch(trackURL(playerURL, track), { credentials: "include" });
    const text = await response.text();
    if (!text) throw new Error("字幕を取得できませんでした");
    this.segments = buildSegments(parseJson3(JSON.parse(text) as Json3));
    if (this.stopped) return;
    if (this.segments.length === 0) return this.setPhase("no-captions", "字幕が空です");

    if (base(track.languageCode) === base(target)) {
      this.setPhase("same-language", "字幕は翻訳先と同じ言語です");
    } else {
      this.sync = new DocumentSync(this.context, {
        document: `yt:${this.video}:${track.vssId ?? track.languageCode}`,
        kind: "captions",
        items: this.segments.map((segment) => ({ id: segment.id, text: segment.text })),
        context: [this.title, this.channel].filter(Boolean).join(" / "),
        sourceLanguage: track.languageCode,
        url: location.href,
        onChange: () => {
          this.renderOverlay();
          this.context.viewChanged();
        },
      });
      this.setPhase("ready");
    }
    this.overlay.setMode(this.overlayMode(this.context.settings()));
    this.watchVideo();
    this.sync?.start();
  }

  /**
   * Chrome's manifest loads the hook into the page's world. Safari cannot, so it is inserted with a script tag
   * there, and with the scripting API if it does not answer (in both browsers).
   */
  private async ensureHook() {
    if (BROWSER === "safari") {
      const tag = document.createElement("script");
      tag.src = ext.runtime.getURL("page-hook.js");
      tag.onload = () => tag.remove();
      (document.head ?? document.documentElement).append(tag);
    }
    for (let attempt = 0; attempt < 20 && !this.hookReady; attempt++) {
      this.postToHook({ kind: "ping" });
      await sleep(100);
      if (attempt === 10 && !this.hookReady) await this.context.injectIntoPage("page-hook.js");
    }
    if (!this.hookReady) throw new Error("ページに接続できませんでした");
  }

  /** The caption tracks the player has for this video (it may still be loading the previous one). */
  private async tracksOfThisVideo() {
    for (let attempt = 0; attempt < 40; attempt++) {
      const requestId = Math.random().toString(36).slice(2);
      const answer = new Promise<Extract<HookMessage, { kind: "tracks" }> | undefined>((resolve) => {
        const listener = (event: MessageEvent) => {
          if (event.data?.source === HOOK_SOURCE && event.data.kind === "tracks" && event.data.requestId === requestId) {
            removeEventListener("message", listener);
            resolve(event.data);
          }
        };
        addEventListener("message", listener);
        setTimeout(() => {
          removeEventListener("message", listener);
          resolve(undefined);
        }, 500);
      });
      this.postToHook({ kind: "get-tracks", requestId });
      const info = await answer;
      if (this.stopped) throw new Error("stopped");
      if (info && info.videoId === this.video) return info;
      await sleep(250);
    }
    throw new Error("動画の情報を読めませんでした");
  }

  /**
   * A caption URL the player requested for this video, with its token. The first request after a page load can
   * go out before the token is ready, so captions are switched off and on again until one carries it.
   */
  private async playerCaptionURL(): Promise<string> {
    if (this.potURL) return this.potURL;
    const got = new Promise<string>((resolve) => this.potWaiters.push(resolve));
    for (let attempt = 0; attempt < 6; attempt++) {
      const winner = await Promise.race([got, sleep(attempt === 0 ? 1500 : 3000).then(() => undefined)]);
      if (winner) return winner;
      if (this.stopped) throw new Error("stopped");
      this.toggleCaptions();
    }
    throw new Error("字幕の取得を始められませんでした（字幕ボタンを押すと再試行します）");
  }

  private toggleCaptions() {
    const button = this.captionsButton();
    if (!button) return;
    if (button.getAttribute("aria-pressed") === "true") {
      button.click();
      setTimeout(() => {
        if (!this.potURL) button.click();
      }, 300);
    } else {
      button.click();
      this.captionsSwitchedOn = true;
    }
  }

  /** YouTube's captions go back off if we switched them on and the video is to show YouTube's own (they were off). */
  private restoreCaptions() {
    if (!this.captionsSwitchedOn || this.context.settings().captionOverlay !== "off") return;
    this.captionsSwitchedOn = false;
    const button = this.captionsButton();
    if (button?.getAttribute("aria-pressed") === "true") button.click();
  }

  private captionsButton() {
    return document.querySelector<HTMLButtonElement>("#movie_player .ytp-subtitles-button");
  }

  private hookMessage(event: MessageEvent) {
    if (event.source !== window || event.data?.source !== HOOK_SOURCE) return;
    const message = event.data as HookMessage;
    if (message.kind === "ready") {
      this.hookReady = true;
    } else if (message.kind === "timedtext" && message.hasPot && message.videoId === this.video && !this.potURL) {
      this.potURL = message.url;
      for (const resolve of this.potWaiters.splice(0)) resolve(message.url);
    }
  }

  private postToHook(message: HookRequest) {
    window.postMessage({ source: CONTENT_SOURCE, ...message }, location.origin);
  }

  private setPhase(phase: CaptionsPhase, message?: string) {
    this.phase = phase;
    this.message = message;
    this.context.viewChanged();
  }

  private fail(message: string) {
    if (this.stopped) return;
    this.setPhase("error", message);
  }

  /** The button in the player opens the sidebar; YouTube rebuilds its controls now and then, so it is checked. */
  private keepPlayerButton() {
    const check = () => {
      const player = document.getElementById("movie_player");
      if (player) ensurePlayerButton(player, () => this.context.toggleSidebar());
    };
    check();
    this.buttonTimer = setInterval(check, 2000);
  }

  // MARK: Playback

  private watchVideo() {
    const attach = () => {
      const player = document.getElementById("movie_player");
      const video = player?.querySelector("video");
      if (!player || !video) return false;
      this.overlay.attach(player);
      this.videoElement = video;
      for (const name of ["timeupdate", "seeked", "play", "pause"]) video.addEventListener(name, this.onTime);
      this.updateTime();
      return true;
    };
    if (attach()) return;
    const timer = setInterval(() => {
      if (this.stopped || attach()) clearInterval(timer);
    }, 500);
  }

  private unwatchVideo() {
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    for (const name of ["timeupdate", "seeked", "play", "pause"]) this.videoElement?.removeEventListener(name, this.onTime);
    this.videoElement = undefined;
  }

  /** Follows the playback position every frame while playing (timeupdate alone is only 4 times a second). */
  private updateTime() {
    const video = this.videoElement;
    if (!video || this.stopped) return;
    const player = document.getElementById("movie_player");
    // During an ad the video element plays the ad.
    const ad = player?.classList.contains("ad-showing") ?? false;
    const time = video.currentTime * 1000;
    const index = ad ? -1 : segmentAt(this.segments, time);
    if (index !== this.activeIndex) {
      this.activeIndex = index;
      this.renderOverlay();
    }
    if (!ad) {
      const focus = segmentAtOrAfter(this.segments, time);
      this.sync?.setFocus(this.segments[focus]?.id);
    }
    if (this.context.hasSidebar()) this.context.tick({ time, activeId: this.segments[index]?.id });
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    this.frame = video.paused ? undefined : requestAnimationFrame(() => this.updateTime());
  }

  /**
   * What the video shows: the setting, except for captions already in the target language, where YouTube's own
   * captions stay (there is no translation to show in their place).
   */
  private overlayMode(settings: Settings): Settings["captionOverlay"] {
    return this.phase === "same-language" ? "off" : settings.captionOverlay;
  }

  private renderOverlay() {
    const segment = this.segments[this.activeIndex];
    if (!segment || this.phase === "same-language") {
      this.overlay.show(null);
      return;
    }
    const result = this.sync?.results.get(segment.id);
    const translation = result?.text;
    if (result?.state === "skipped" || (!translation && this.sync?.status.state !== "ok")) {
      // Not translated (or the app is not there): YouTube's own captions are better than nothing.
      this.overlay.show(null);
      document.getElementById("movie_player")?.classList.remove("plamonic-captions-active");
      return;
    }
    this.overlay.setMode(this.overlayMode(this.context.settings()));
    this.overlay.show({ translation: translation ?? "", original: segment.text, pending: !translation });
  }
}
