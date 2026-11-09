/**
 * Messages to and from the Plamonic app (docs/DESIGN.md §9, Plamonic/Bridge/BridgeProtocol.swift).
 * The extension sends them through the browser's native messaging; Safari's extension and Chrome's native host
 * forward them to the app's socket unchanged.
 */
import type { SiteInfo } from "./sites";

export const BRIDGE_PROTOCOL = 1;

export type BridgeRequest =
  /** With `url`, `targetLanguage` is that page's (its site may override the global one). */
  | { type: "hello"; url?: string }
  | {
      type: "sync";
      document: string;
      kind?: "captions" | "page";
      items?: { id: string; text: string }[];
      focus?: string;
      urgent?: number;
      /** The items on screen, top to bottom (a page): translated first. */
      visible?: string[];
      want?: string[];
      context?: string;
      sourceLanguage?: string;
      /** The page: its site's settings (target language, context) apply. */
      url?: string;
    }
  | { type: "close"; document: string }
  | { type: "translate"; texts: string[]; context?: string; sourceLanguage?: string; url?: string }
  /** The website settings for a page. */
  | { type: "site"; url: string }
  /** The sites set to translate by themselves. */
  | { type: "sites" }
  /** Sets the mode of the page's site in the app's settings; answers `site`. */
  | { type: "setSite"; url: string; mode: "off" | "automatic" | "manual" };

export type ResultState = "pending" | "draft" | "final" | "failed" | "skipped";

export interface BridgeResult {
  id: string;
  state: ResultState;
  text?: string;
}

/** Why a request failed. `appNotRunning` comes from the native side when the app's socket is not there. */
export type BridgeError = "badRequest" | "unknownDocument" | "disabled" | "tooLarge" | "appNotRunning" | "unreachable";

export interface BridgeResponse {
  id?: number | string;
  ok: boolean;
  error?: BridgeError | string;
  message?: string;
  // hello
  protocol?: number;
  app?: string;
  version?: string;
  enabled?: boolean;
  targetLanguage?: string;
  ready?: boolean;
  features?: string[];
  // sync
  results?: BridgeResult[];
  progress?: { done: number; total: number };
  // translate
  translations?: (string | null)[];
  // site, sites
  site?: SiteInfo;
  sites?: SiteInfo[];
}

/** What the extension knows about the app, shown in the sidebar header. */
export type BridgeStatus =
  | { state: "unknown" }
  | { state: "connected"; version: string; enabled: boolean; ready: boolean; targetLanguage: string; features: string[] }
  | { state: "unreachable"; message: string };
