import type { ResultState } from "../../shared/bridge-types";

/** The YouTube captions feature's sidebar data (`ViewState` with kind "youtube-captions"). */
export const CAPTIONS_VIEW = "youtube-captions";

export type CaptionsPhase =
  /** Not a video page. */
  | "idle"
  /** Looking for the captions of this video. */
  | "loading"
  | "no-captions"
  /** The captions are already in the target language: shown, not translated. */
  | "same-language"
  | "ready"
  | "error";

export interface CaptionsViewState {
  kind: typeof CAPTIONS_VIEW;
  phase: CaptionsPhase;
  message?: string;
  videoId?: string;
  title?: string;
  channel?: string;
  track?: { language: string; name: string; automatic: boolean };
  /** The app connection for this video. */
  bridge: { state: "connecting" | "ok" | "unreachable" | "disabled" | "error"; message?: string };
  progress?: { done: number; total: number };
  lines: CaptionLine[];
  activeId?: string;
}

export interface CaptionLine {
  id: string;
  /** Milliseconds. */
  start: number;
  text: string;
  translation?: string;
  state: ResultState;
}

/** The frequent update between full views. */
export interface CaptionsTick {
  time: number;
  activeId?: string;
}

export type CaptionsCommand = { command: "seek"; args: { time: number } } | { command: "retry"; args?: undefined };
