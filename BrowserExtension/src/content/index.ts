import { resumeAction, startAction, type PageAction, type PageActions } from "../shared/actions";
import { isPaused, setPaused } from "../shared/pause";
import { BROWSER, ext, sendRuntime } from "../shared/api";
import type { BridgeResponse } from "../shared/bridge-types";
import {
  SIDEBAR_PORT,
  TOGGLE_SIDEBAR_EVENT,
  type BackgroundMessage,
  type ContentMessage,
  type ContentToSidebar,
  type SidebarToContent,
  type ViewState,
} from "../shared/messages";
import { DEFAULT_SETTINGS, loadSettings, onSettingsChanged, type Settings } from "../shared/settings";
import type { SiteInfo } from "../shared/sites";
import { FEATURES } from "../features";
import { SidebarShell } from "../sidebar/shell";
import { EmbeddedSidebar } from "./embedded-sidebar";
import type { Feature, FeatureContext, FeatureInstance } from "./feature";
import { showToast } from "./toast";

declare global {
  interface Window {
    __plamonicContent?: boolean;
  }
}

/** An open sidebar: Chrome's side panel (over a port) or Safari's sidebar in this page. */
interface SidebarConnection {
  post(message: ContentToSidebar): void;
}

/**
 * Runs the page's features, answers the toolbar menu, and serves the sidebars open for this tab. It is loaded
 * by the manifest on the sites of auto features, and injected by the toolbar menu elsewhere.
 */
class ContentHost {
  private running = new Map<string, { feature: Feature; instance: FeatureInstance }>();
  private settings: Settings = { ...DEFAULT_SETTINGS };
  private connections = new Set<SidebarConnection>();
  private viewTimer: number | undefined;
  private lastURL = location.href;
  private embedded = new EmbeddedSidebar();
  private embeddedShell: { shell: SidebarShell; connection: SidebarConnection } | undefined;
  private site: SiteInfo | undefined;
  private siteURL: string | undefined;
  /** Automatic translation of this site is paused from the menu. */
  private paused = false;
  /** Settles once the site's settings are known (or the app did not answer). */
  private siteReady: Promise<void> = Promise.resolve();

  async run() {
    ext.runtime.onConnect.addListener((port) => this.connect(port));
    ext.runtime.onMessage.addListener((message: ContentMessage, _sender, sendResponse) => {
      switch (message?.type) {
        case "sidebar:toggle":
          void this.toggleSidebar();
          sendResponse({ ok: true });
          return false;
        case "page:actions":
          sendResponse(this.actions());
          return false;
        case "page:action":
          this.perform(message.id, message.value);
          sendResponse(this.actions());
          return false;
        default:
          return false;
      }
    });
    addEventListener(TOGGLE_SIDEBAR_EVENT, () => void this.toggleSidebar());
    this.siteReady = this.loadSite();
    this.settings = await loadSettings();
    onSettingsChanged((settings) => {
      this.settings = settings;
      for (const { instance } of this.running.values()) instance.settingsChanged?.(settings);
    });
    // Single-page sites change the address without loading a page.
    for (const event of ["popstate", "yt-navigate-finish"]) addEventListener(event, () => this.checkURL());
    setInterval(() => this.checkURL(), 1000);
    this.startAutoFeatures();
  }

  /** The app's settings for this site; on an automatic site, starts the features that follow the site's mode. */
  private async loadSite() {
    const url = location.href;
    const site = await sendRuntime<SiteInfo>({ type: "site:get", url } satisfies BackgroundMessage);
    if (location.href !== url) return;
    this.site = site;
    this.siteURL = url;
    this.paused = site ? await isPaused(site.pattern) : false;
    if (site?.mode !== "automatic" || this.paused) return;
    const page = new URL(url);
    for (const feature of FEATURES) {
      if (feature.followsSiteMode && feature.matches(page) && !this.running.has(feature.id)) this.start(feature);
    }
  }

  // MARK: Features

  private startAutoFeatures() {
    const url = new URL(location.href);
    for (const feature of FEATURES) {
      if (feature.activation === "auto" && feature.matches(url) && !this.running.has(feature.id)) this.start(feature);
    }
  }

  private start(feature: Feature) {
    const instance = feature.create(this.context(feature));
    this.running.set(feature.id, { feature, instance });
    instance.start();
    this.scheduleView();
  }

  private stop(id: string) {
    const entry = this.running.get(id);
    if (!entry) return;
    this.running.delete(id);
    entry.instance.stop();
    this.scheduleView();
  }

  private checkURL() {
    if (location.href === this.lastURL) return;
    this.lastURL = location.href;
    const url = new URL(location.href);
    for (const [id, { instance }] of [...this.running]) {
      if (!instance.urlChanged?.(url)) this.stop(id);
    }
    this.startAutoFeatures();
    this.scheduleView();
    // Another part of a single-page site may have other settings (a path pattern).
    if (this.siteURL !== location.href) this.siteReady = this.loadSite();
  }

  private context(feature: Feature): FeatureContext {
    return {
      bridge: async (request) =>
        (await sendRuntime<BridgeResponse>({ type: "bridge:call", request } satisfies BackgroundMessage)) ?? {
          ok: false,
          error: "unreachable",
          message: "拡張機能のバックグラウンドに届きません",
        },
      injectIntoPage: async (file) => {
        const reply = await sendRuntime<{ ok: boolean }>({ type: "inject:main", file } satisfies BackgroundMessage);
        return reply?.ok ?? false;
      },
      settings: () => this.settings,
      viewChanged: () => this.scheduleView(),
      tick: (tick) => this.post({ type: "tick", tick }),
      hasSidebar: () => this.connections.size > 0,
      toggleSidebar: () => void this.toggleSidebar(),
      finished: () => this.stop(feature.id),
      site: () => this.site,
      pauseSite: () => {
        if (!this.site) return;
        this.paused = true;
        void setPaused(this.site.pattern, true);
        this.stop(feature.id);
      },
    };
  }

  // MARK: Toolbar menu

  private actions(): PageActions {
    const url = new URL(location.href);
    const actions: PageAction[] = [];
    for (const { feature, instance } of this.running.values()) {
      for (const action of instance.actions?.() ?? []) actions.push({ ...action, id: `${feature.id}:${action.id}` });
    }
    for (const feature of FEATURES) {
      if (feature.activation !== "manual" || this.running.has(feature.id) || !feature.matches(url)) continue;
      if (feature.followsSiteMode && this.site?.mode === "off") continue;
      if (feature.followsSiteMode && this.site?.mode === "automatic" && this.paused) {
        actions.push({ id: resumeAction(feature.id), kind: "button", label: "自動翻訳を再開", icon: "resume" });
        continue;
      }
      actions.push({ id: startAction(feature.id), kind: "button", label: feature.startLabel ?? feature.id, icon: "translate" });
    }
    const hasView = this.view().kind !== "none";
    return {
      actions,
      sidebar: { available: hasView, label: this.embeddedShell ? "サイドバーを閉じる" : "サイドバーを開く" },
    };
  }

  private perform(id: string, value?: string) {
    if (id.startsWith("resume:") || id.startsWith("start:")) {
      const resume = id.startsWith("resume:");
      const feature = FEATURES.find((candidate) => candidate.id === id.slice(id.indexOf(":") + 1));
      if (resume && this.site) {
        this.paused = false;
        void setPaused(this.site.pattern, false);
      }
      // After the site's settings are known: they say where to translate.
      void this.siteReady.then(() => {
        if (feature && !this.running.has(feature.id) && feature.matches(new URL(location.href))) this.start(feature);
      });
      return;
    }
    const separator = id.indexOf(":");
    const entry = this.running.get(id.slice(0, separator));
    entry?.instance.perform?.(id.slice(separator + 1), value);
  }

  // MARK: Sidebar

  /** The first running feature that has something for the sidebar. */
  private view(): ViewState {
    for (const { instance } of this.running.values()) {
      const view = instance.view?.();
      if (view) return view;
    }
    return { kind: "none" };
  }

  private command(command: string, args: unknown) {
    for (const { instance } of this.running.values()) instance.command?.(command, args);
  }

  /** Chrome: its side panel for this tab. Safari: the sidebar inside the page. */
  private async toggleSidebar() {
    if (BROWSER === "chrome") {
      const reply = await sendRuntime<{ ok: boolean }>({ type: "sidebar:open" } satisfies BackgroundMessage);
      if (!reply?.ok) showToast("ツールバーの Plamonic メニューからサイドバーを開いてください", "warn");
      return;
    }
    if (this.embeddedShell) return this.closeEmbedded();
    try {
      const shell = new SidebarShell({
        command: (command, args) => this.command(command, args),
        onClose: () => this.closeEmbedded(),
      });
      const connection: SidebarConnection = { post: (message) => shell.receive(message) };
      this.embeddedShell = { shell, connection };
      await this.embedded.open(shell);
      this.connections.add(connection);
      shell.show(this.view());
    } catch (error) {
      this.closeEmbedded();
      showToast(`サイドバーを開けませんでした: ${String((error as Error)?.message ?? error)}`, "error");
    }
  }

  private closeEmbedded() {
    const open = this.embeddedShell;
    this.embeddedShell = undefined;
    this.embedded.close();
    if (!open) return;
    this.connections.delete(open.connection);
    open.shell.destroy();
  }

  /** Chrome's side panel connects over a port. */
  private connect(port: chrome.runtime.Port) {
    if (port.name !== SIDEBAR_PORT) return;
    const connection: SidebarConnection = { post: (message) => port.postMessage(message) };
    this.connections.add(connection);
    port.onDisconnect.addListener(() => this.connections.delete(connection));
    port.onMessage.addListener((message: SidebarToContent) => {
      if (message.type === "command") this.command(message.command, message.args);
    });
    connection.post({ type: "view", view: this.view() });
  }

  private scheduleView() {
    if (this.viewTimer !== undefined || this.connections.size === 0) return;
    this.viewTimer = window.setTimeout(() => {
      this.viewTimer = undefined;
      this.post({ type: "view", view: this.view() });
    }, 200);
  }

  private post(message: ContentToSidebar) {
    for (const connection of this.connections) {
      try {
        connection.post(message);
      } catch {
        this.connections.delete(connection);
      }
    }
  }
}

// The toolbar menu may inject this file into a page that already has it.
if (!window.__plamonicContent) {
  window.__plamonicContent = true;
  void new ContentHost().run();
}
