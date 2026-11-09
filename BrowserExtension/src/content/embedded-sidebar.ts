import { ext } from "../shared/api";
import { SIDEBAR_STYLE, type SidebarShell } from "../sidebar/shell";

/** In the extension's storage, not the site's. */
const WIDTH_KEY = "sidebarWidth";

/**
 * Safari's sidebar: the sidebar shell placed on the right edge of the page, inside a shadow root so the site's
 * styles cannot reach it. The page is narrowed to make room, and the left edge can be dragged to resize it.
 * (Chrome uses its side panel instead.)
 */
export class EmbeddedSidebar {
  private host: HTMLElement | undefined;
  private pageStyle: HTMLStyleElement | undefined;

  get isOpen() {
    return this.host !== undefined;
  }

  async open(shell: SidebarShell) {
    if (this.isOpen) return;
    const width = await this.savedWidth();
    const host = document.createElement("plamonic-sidebar");
    const shadow = host.attachShadow({ mode: "open" });
    const style = document.createElement("style");
    style.textContent = `
      :host { all: initial; position: fixed; top: 0; right: 0; bottom: 0; z-index: 2147483646;
        width: var(--plamonic-width, 380px); box-shadow: -1px 0 0 rgba(0,0,0,.12), -8px 0 24px rgba(0,0,0,.12); }
      .grip { position: absolute; top: 0; bottom: 0; left: -3px; width: 6px; cursor: ew-resize; z-index: 1; }
      ${SIDEBAR_STYLE}`;
    const grip = document.createElement("div");
    grip.className = "grip";
    shadow.append(style, grip, shell.element);
    this.makeResizable(grip, host);
    this.pageStyle = document.createElement("style");
    document.documentElement.append(this.pageStyle);
    this.host = host;
    this.setWidth(width);
    document.documentElement.append(host);
  }

  close() {
    this.host?.remove();
    this.pageStyle?.remove();
    this.host = undefined;
    this.pageStyle = undefined;
  }

  private setWidth(width: number) {
    this.host?.style.setProperty("--plamonic-width", `${width}px`);
    // Make room so the sidebar covers nothing; YouTube's fixed header narrows with the page.
    if (this.pageStyle) {
      this.pageStyle.textContent = `html { margin-right: ${width}px !important; }
        ytd-app #masthead-container { right: ${width}px !important; width: auto !important; }`;
    }
  }

  private async savedWidth() {
    let saved = NaN;
    try {
      saved = Number((await ext.storage.local.get(WIDTH_KEY))[WIDTH_KEY]);
    } catch {}
    return Number.isFinite(saved) && saved >= 280 ? Math.min(saved, 720) : 380;
  }

  private makeResizable(grip: HTMLElement, host: HTMLElement) {
    grip.addEventListener("pointerdown", (down) => {
      down.preventDefault();
      grip.setPointerCapture(down.pointerId);
      const move = (event: PointerEvent) => {
        this.setWidth(Math.min(Math.max(innerWidth - event.clientX, 280), Math.min(720, innerWidth - 200)));
      };
      const up = () => {
        grip.removeEventListener("pointermove", move);
        const width = parseInt(host.style.getPropertyValue("--plamonic-width"), 10);
        if (width) void ext.storage.local.set({ [WIDTH_KEY]: width }).catch(() => {});
      };
      grip.addEventListener("pointermove", move);
      grip.addEventListener("pointerup", up, { once: true });
    });
  }
}
