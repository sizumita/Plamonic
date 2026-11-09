import type { BridgeRequest, BridgeResponse, BridgeStatus } from "./bridge-types";
import type { SiteInfo } from "./sites";

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
  | { type: "sidebar:open" }
  /** The website settings for a page, from the app (undefined when it is not reachable). */
  | { type: "site:get"; url: string }
  /** Re-reads the automatic sites from the app and runs the content script on those the user allowed. */
  | { type: "sites:refresh" }
  /** Sets the page's site to `mode` in the app's settings (the menu's 「このサイトを自動で翻訳」). */
  | { type: "site:set"; url: string; mode: "off" | "automatic" | "manual" };

export type BackgroundReply = {
  "bridge:call": BridgeResponse;
  "bridge:status": BridgeStatus;
  "tab:id": number | undefined;
  "inject:main": { ok: boolean; error?: string };
  "sidebar:open": { ok: boolean; error?: string };
  "site:get": SiteInfo | undefined;
  "sites:refresh": { registered: string[] };
  "site:set": SiteInfo | undefined;
};

/**
 * To the content script of a tab (from the background or the toolbar menu).
 * - sidebar:toggle answers `{ok: true}`, so the sender knows it arrived.
 * - page:actions answers PageActions.
 * - page:action runs one (`start:<feature>` starts a manual feature) and answers the new PageActions.
 */
export type ContentMessage =
  | { type: "sidebar:toggle" }
  | { type: "page:actions" }
  | { type: "page:action"; id: string; value?: string };

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
