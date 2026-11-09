import type { PageAction } from "../shared/actions";
import type { BridgeRequest, BridgeResponse } from "../shared/bridge-types";
import type { ViewState } from "../shared/messages";
import type { Settings } from "../shared/settings";
import type { SiteInfo } from "../shared/sites";

/**
 * A feature is something the extension does on a kind of page: YouTube captions, translating a page's text, and
 * whatever comes next. The content script runs every feature that applies:
 *
 * - `auto` features start by themselves on the pages they match (YouTube captions on a video page) and stop when
 *   the page changes;
 * - `manual` features start when chosen in the toolbar menu (`startLabel`), and stop through their own action.
 *
 * Adding a feature: write it, add it to `features/index.ts`; for an auto feature, add its sites to
 * CONTENT_MATCHES in scripts/build.mjs (manual ones are injected on request, on any site); if it shows something
 * in the sidebar, register a view for its `ViewState.kind` in `sidebar/views/index.ts`.
 */
export interface Feature {
  id: string;
  activation: "auto" | "manual";
  /** For manual features: the toolbar menu item that starts it. */
  startLabel?: string;
  /**
   * For manual features: also started by itself on sites set to "自動" in the app, and never offered on sites set
   * to "オフ" (page translation).
   */
  followsSiteMode?: boolean;
  matches(url: URL): boolean;
  create(context: FeatureContext): FeatureInstance;
}

export interface FeatureInstance {
  start(): void;
  stop(): void;
  /** The page's address changed without a reload (single-page sites). Return false to be stopped instead. */
  urlChanged?(url: URL): boolean;
  /** What the sidebar shows, or undefined when this feature has nothing for it. */
  view?(): ViewState | undefined;
  /** What the toolbar menu offers while it runs. Ids are local to the feature. */
  actions?(): PageAction[];
  /** An action from the toolbar menu (`value` for choices). */
  perform?(action: string, value?: string): void;
  /** A command from the sidebar's view, such as "seek". */
  command?(command: string, args: unknown): void;
  settingsChanged?(settings: Settings): void;
}

export interface FeatureContext {
  /** The app, through the background. */
  bridge(request: BridgeRequest): Promise<BridgeResponse>;
  /** Runs one of our files in the page's own world (for hooks into the page's scripts). */
  injectIntoPage(file: string): Promise<boolean>;
  settings(): Settings;
  /** The view changed: open sidebars get `view()` (coalesced). */
  viewChanged(): void;
  /** A small frequent update for open sidebars, such as the playback position. */
  tick(data: unknown): void;
  /** Whether a sidebar is open for this tab, so a feature can skip work nobody sees. */
  hasSidebar(): boolean;
  /** Opens (or, where it lives in the page, toggles) the sidebar, such as from a button the feature adds. */
  toggleSidebar(): void;
  /** The feature ended itself (a manual feature's "stop" action). */
  finished(): void;
  /** This site's settings in the app (Settings › Webサイト), once known; undefined when the app is not reachable. */
  site(): SiteInfo | undefined;
  /** Stops the feature and keeps it from starting by itself on this site until resumed from the menu. */
  pauseSite(): void;
}
