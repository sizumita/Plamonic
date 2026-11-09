import type { BridgeRequest, BridgeResponse, BridgeStatus } from "./bridge-types";

/**
 * Messages inside the extension.
 *
 *   content script ──runtime.sendMessage──▶ background   (BackgroundMessage)
 *   background     ──tabs.sendMessage────▶ content      (ContentMessage)
 *   Chrome's side panel ──tabs.connect("sidebar")─▶ content  (a port: SidebarToContent / ContentToSidebar)
 *
 * The side panel talks to the tab's content script directly over a port, so updates flow only while a sidebar
 * is open and never wake the background. Safari's sidebar runs inside the page and gets the same messages
 * without a port (content/index.ts).
 */
export type BackgroundMessage =
  | { type: "bridge:call"; request: BridgeRequest }
  | { type: "bridge:status"; refresh?: boolean }
  | { type: "tab:id" }
  | { type: "inject:main"; file: string }
  /** Chrome: open the side panel (from a click in the page). */
  | { type: "sidebar:open" };

export type BackgroundReply = {
  "bridge:call": BridgeResponse;
  "bridge:status": BridgeStatus;
  "tab:id": number | undefined;
  "inject:main": { ok: boolean; error?: string };
  "sidebar:open": { ok: boolean; error?: string };
};

/** The content script answers `{ok: true}`, so the background knows it arrived. */
export type ContentMessage = { type: "sidebar:toggle" };

/** A window event the background can fire in the page when a message cannot reach the content script. */
export const TOGGLE_SIDEBAR_EVENT = "plamonic:toggle-sidebar";

export const SIDEBAR_PORT = "sidebar";

/**
 * What a feature shows in the sidebar. `kind` picks the sidebar view; the rest is that view's data (each feature
 * defines its own type, such as CaptionsViewState). It crosses to the sidebar by structured clone.
 */
export interface ViewState {
  readonly kind: string;
}

export type ContentToSidebar =
  | { type: "view"; view: ViewState }
  /** Frequent, small updates (the playback position) between full views. */
  | { type: "tick"; tick: unknown };

export type SidebarToContent = { type: "command"; command: string; args?: unknown };
