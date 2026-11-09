import { sendRuntime } from "../shared/api";
import type { BridgeStatus } from "../shared/bridge-types";
import type { BackgroundMessage, ContentToSidebar, ViewState } from "../shared/messages";
import STYLE from "./style.css";
import { fallbackView, VIEWS } from "./views";
import type { SidebarView } from "./views/view";

export { STYLE as SIDEBAR_STYLE };

export interface ShellOptions {
  /** Shows a close button (the sidebar inside the page). */
  onClose?: () => void;
  /** Sends a command from a view to the feature in the page. */
  command: (command: string, args?: unknown) => void;
}

/**
 * The sidebar's user interface: a header with the app status and the view for the page's feature. It runs as
 * Chrome's side panel page and, in Safari, directly inside the page (in a shadow root; Safari has no side panel,
 * and an extension page in an iframe in the site crashed it). The host feeds it `ContentToSidebar` messages.
 */
export class SidebarShell {
  readonly element: HTMLElement;
  private readonly viewRoot: HTMLElement;
  private readonly statusChip: HTMLElement;
  private view: SidebarView | undefined;
  private viewKind: string | undefined;
  private statusTimer: ReturnType<typeof setInterval>;

  constructor(private readonly options: ShellOptions) {
    this.element = document.createElement("div");
    this.element.className = "plamonic-sidebar";
    const bar = document.createElement("header");
    bar.className = "bar";
    bar.innerHTML = `<svg class="logo" viewBox="0 0 1024 1024" aria-hidden="true">
        <rect x="40" y="40" width="944" height="944" rx="210" fill="#3d5ef0"/>
        <path fill="#fff" d="M362 214 H662 A176 176 0 0 1 838 390 V546 A176 176 0 0 1 662 722 H488 C444 772 372 818 280 838 C318 796 338 756 344 721 A176 176 0 0 1 186 546 V390 A176 176 0 0 1 362 214 Z"/>
        <path fill="none" stroke="#2F54EB" stroke-width="76" stroke-linecap="round" stroke-linejoin="round" d="M427 606 V340 H514 A94 94 0 0 1 514 528 H427"/>
      </svg><span class="name">Plamonic</span>`;
    this.statusChip = document.createElement("span");
    this.statusChip.className = "status";
    this.statusChip.dataset.state = "unknown";
    this.statusChip.textContent = "確認中…";
    bar.append(this.statusChip);
    if (options.onClose) {
      const close = document.createElement("button");
      close.className = "icon close";
      close.title = "閉じる";
      close.textContent = "✕";
      close.addEventListener("click", () => options.onClose?.());
      bar.append(close);
    }
    this.viewRoot = document.createElement("div");
    this.viewRoot.className = "view";
    this.element.append(bar, this.viewRoot);
    void this.refreshStatus(true);
    this.statusTimer = setInterval(() => void this.refreshStatus(), 5000);
  }

  receive(message: ContentToSidebar) {
    if (message.type === "view") this.show(message.view);
    else this.view?.tick?.(message.tick);
  }

  show(state: ViewState) {
    if (state.kind !== this.viewKind) {
      this.view?.unmount?.();
      const factory = VIEWS[state.kind] ?? fallbackView;
      this.view = factory({ command: (command, args) => this.options.command(command, args) });
      this.viewKind = state.kind;
      this.view.mount(this.viewRoot);
    }
    this.view!.update(state);
  }

  destroy() {
    clearInterval(this.statusTimer);
    this.view?.unmount?.();
    this.element.remove();
  }

  private async refreshStatus(refresh = false) {
    const status = await sendRuntime<BridgeStatus>({ type: "bridge:status", refresh } satisfies BackgroundMessage);
    const chip = this.statusChip;
    chip.dataset.state = status?.state === "connected" && !status.enabled ? "disabled" : (status?.state ?? "unknown");
    if (status?.state === "connected") {
      chip.textContent = status.enabled ? `接続済み ・ v${status.version}` : "翻訳の提供がオフ";
      chip.title = `Plamonic ${status.version}、翻訳先: ${status.targetLanguage}`;
    } else if (status?.state === "unreachable") {
      chip.textContent = "Plamonic 未起動";
      chip.title = status.message;
    } else {
      chip.textContent = "確認中…";
    }
  }
}
