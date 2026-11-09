import type { ContentToSidebar, ViewState } from "../shared/messages";
import STYLE from "./style.css";
import { fallbackView, VIEWS } from "./views";
import type { SidebarView } from "./views/view";

export { STYLE as SIDEBAR_STYLE };

export interface ShellOptions {
  /** Shows a slim title bar with a close button: Safari's sidebar inside the page, which has no frame of its own.
   * Chrome's side panel has its own title and close button, so it gets none. */
  onClose?: () => void;
  /** Sends a command from a view to the feature in the page. */
  command: (command: string, args?: unknown) => void;
}

/**
 * The sidebar's user interface: the view for the page's feature (and, in Safari, a slim title bar). It runs as
 * Chrome's side panel page and, in Safari, directly inside the page (in a shadow root; Safari has no side panel,
 * and an extension page in an iframe in the site crashed it). The host feeds it `ContentToSidebar` messages.
 * Problems with the app (not running, turned off) are shown by the views where they matter.
 */
export class SidebarShell {
  readonly element: HTMLElement;
  private readonly viewRoot: HTMLElement;
  private view: SidebarView | undefined;
  private viewKind: string | undefined;

  constructor(private readonly options: ShellOptions) {
    this.element = document.createElement("div");
    this.element.className = "plamonic-sidebar";
    if (options.onClose) {
      const bar = document.createElement("header");
      bar.className = "bar";
      bar.innerHTML = `<svg class="logo" viewBox="0 0 1024 1024" aria-hidden="true">
          <rect x="40" y="40" width="944" height="944" rx="210" fill="#3d5ef0"/>
          <path fill="#fff" d="M362 214 H662 A176 176 0 0 1 838 390 V546 A176 176 0 0 1 662 722 H488 C444 772 372 818 280 838 C318 796 338 756 344 721 A176 176 0 0 1 186 546 V390 A176 176 0 0 1 362 214 Z"/>
          <path fill="none" stroke="#2F54EB" stroke-width="76" stroke-linecap="round" stroke-linejoin="round" d="M427 606 V340 H514 A94 94 0 0 1 514 528 H427"/>
        </svg><span class="name">Plamonic</span>`;
      const close = document.createElement("button");
      close.className = "icon close";
      close.title = "閉じる";
      close.setAttribute("aria-label", "閉じる");
      close.innerHTML = `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>`;
      close.addEventListener("click", () => options.onClose?.());
      bar.append(close);
      this.element.append(bar);
    }
    this.viewRoot = document.createElement("div");
    this.viewRoot.className = "view";
    this.element.append(this.viewRoot);
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
    this.view?.unmount?.();
    this.element.remove();
  }
}
