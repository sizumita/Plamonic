import { BROWSER, ext, sendRuntime } from "../shared/api";
import type { BridgeResponse } from "../shared/bridge-types";
import {
  SIDEBAR_PORT,
  type BackgroundMessage,
  TOGGLE_SIDEBAR_EVENT,
  type ContentMessage,
  type ContentToSidebar,
  type SidebarToContent,
  type ViewState,
} from "../shared/messages";
import { loadSettings, onSettingsChanged, DEFAULT_SETTINGS, type Settings } from "../shared/settings";
import { FEATURES } from "../features";
import { SidebarShell } from "../sidebar/shell";
import { EmbeddedSidebar } from "./embedded-sidebar";
import { showToast } from "./toast";
import type { FeatureContext, FeatureInstance } from "./feature";

/** An open sidebar: Chrome's side panel (over a port) or Safari's sidebar in this page. */
interface SidebarConnection {
  post(message: ContentToSidebar): void;
}

/** Runs the feature for the current page and serves the sidebars open for this tab. */
class ContentHost {
  private instance: FeatureInstance | undefined;
  private settings: Settings = { ...DEFAULT_SETTINGS };
  private connections = new Set<SidebarConnection>();
  private viewTimer: number | undefined;
  private lastURL = location.href;
  private embedded = new EmbeddedSidebar();
  private embeddedShell: { shell: SidebarShell; connection: SidebarConnection } | undefined;

  async run() {
    this.settings = await loadSettings();
    onSettingsChanged((settings) => {
      this.settings = settings;
      this.instance?.settingsChanged?.(settings);
    });
    ext.runtime.onConnect.addListener((port) => this.connect(port));
    ext.runtime.onMessage.addListener((message: ContentMessage, _sender, sendResponse) => {
      if (message?.type !== "sidebar:toggle") return false;
      void this.toggleSidebar();
      sendResponse({ ok: true });
      return false;
    });
    addEventListener(TOGGLE_SIDEBAR_EVENT, () => void this.toggleSidebar());
    // Single-page sites change the address without loading a page.
    for (const event of ["popstate", "yt-navigate-finish"]) addEventListener(event, () => this.checkURL());
    setInterval(() => this.checkURL(), 1000);
    this.select();
  }

  private context(): FeatureContext {
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
    };
  }

  /** Chrome: its side panel. Safari: the sidebar inside the page. */
  private async toggleSidebar() {
    if (BROWSER === "chrome") {
      const reply = await sendRuntime<{ ok: boolean; error?: string }>({ type: "sidebar:open" } satisfies BackgroundMessage);
      if (!reply?.ok) showToast("ツールバーの Plamonic ボタンからサイドパネルを開いてください", "warn");
      return;
    }
    if (this.embeddedShell) return this.closeEmbedded();
    try {
      const shell = new SidebarShell({
        command: (command, args) => this.instance?.command?.(command, args),
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

  private checkURL() {
    if (location.href === this.lastURL) return;
    this.lastURL = location.href;
    const url = new URL(location.href);
    if (this.instance?.urlChanged?.(url)) {
      this.scheduleView();
      return;
    }
    this.select();
  }

  /** Starts the feature for this page, stopping the previous one. */
  private select() {
    const url = new URL(location.href);
    const feature = FEATURES.find((candidate) => candidate.matches(url));
    this.instance?.stop();
    this.instance = feature?.create(this.context());
    this.instance?.start();
    this.scheduleView();
  }

  private view(): ViewState {
    return this.instance?.view() ?? { kind: "none" };
  }

  /** Chrome's side panel connects over a port. */
  private connect(port: chrome.runtime.Port) {
    if (port.name !== SIDEBAR_PORT) return;
    const connection: SidebarConnection = { post: (message) => port.postMessage(message) };
    this.connections.add(connection);
    port.onDisconnect.addListener(() => this.connections.delete(connection));
    port.onMessage.addListener((message: SidebarToContent) => {
      if (message.type === "command") this.instance?.command?.(message.command, message.args);
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

void new ContentHost().run();
