/**
 * Messages to and from the Plamonic app (docs/DESIGN.md §9, Plamonic/Bridge/BridgeProtocol.swift).
 * The extension sends them through the browser's native messaging; Safari's extension and Chrome's native host
 * forward them to the app's socket unchanged.
 */
export const BRIDGE_PROTOCOL = 1;

export type BridgeRequest =
  | { type: "hello" }
  | {
      type: "sync";
      document: string;
      kind?: "captions" | "page";
      items?: { id: string; text: string }[];
      focus?: string;
      urgent?: number;
      want?: string[];
      context?: string;
      sourceLanguage?: string;
    }
  | { type: "close"; document: string }
  | { type: "translate"; texts: string[]; context?: string; sourceLanguage?: string };

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
}

/** What the extension knows about the app, shown in the sidebar header. */
export type BridgeStatus =
  | { state: "unknown" }
  | { state: "connected"; version: string; enabled: boolean; ready: boolean; targetLanguage: string; features: string[] }
  | { state: "unreachable"; message: string };
