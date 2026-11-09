import type { BridgeRequest, BridgeResponse } from "../shared/bridge-types";
import type { ViewState } from "../shared/messages";
import type { Settings } from "../shared/settings";

/**
 * A feature is what the extension does on a kind of page (YouTube captions today; page translation and others
 * later). The content script starts the first feature whose `matches` accepts the page and stops it when the
 * page changes. Adding a feature: write one, add it to `features/index.ts`, add its sites to the manifest's
 * content script matches (scripts/build.mjs), and, if it shows something in the sidebar, register a view for its
 * `ViewState.kind` in `sidebar/views/index.ts`.
 */
export interface Feature {
  id: string;
  matches(url: URL): boolean;
  create(context: FeatureContext): FeatureInstance;
}

export interface FeatureInstance {
  start(): void;
  stop(): void;
  /** The page's address changed without a reload (single-page sites). Return false to be restarted instead. */
  urlChanged?(url: URL): boolean;
  /** What the sidebar shows now. */
  view(): ViewState;
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
}
