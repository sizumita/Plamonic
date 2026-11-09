/**
 * The original of a translated paragraph, in a small popup when the pointer rests on it. The popup stays while the
 * pointer moves into it (to select and copy the original) and goes away when the pointer leaves both, or the page
 * scrolls. It lives in a shadow root at the top of the document, so the site's styles cannot reach it, and outside
 * <body>, so page translation's watch for changes does not see it.
 *
 * The paragraph is found from the element under the pointer when that works, and otherwise by position: the
 * translated paragraph whose box holds the pointer. Many sites lay a transparent link over a whole card (Reddit's
 * posts, so a click anywhere opens it) and make the text ignore the pointer (`pointer-events: none`), so the
 * element under the pointer never is the text.
 */
const SHOW_DELAY_MS = 450;
const HIDE_DELAY_MS = 200;
const GAP = 6;

export class OriginalPopup {
  private host: HTMLElement | undefined;
  private box: HTMLDivElement | undefined;
  private target: Element | undefined;
  /** The paragraph the pointer is on, waiting for the show delay. */
  private pending: Element | undefined;
  private showTimer: ReturnType<typeof setTimeout> | undefined;
  private hideTimer: ReturnType<typeof setTimeout> | undefined;
  private frame: number | undefined;
  private pointer = { x: 0, y: 0 };
  private readonly onMove = (event: PointerEvent) => this.move(event);
  private readonly onLeave = (event: PointerEvent) => {
    if (!event.relatedTarget) this.scheduleHide();
  };
  private readonly onScroll = () => this.hide();

  /**
   * `selector` matches translated paragraphs; `candidates` lists them all, for the search by position; `original`
   * gives a paragraph's original (undefined when it is not translated).
   */
  constructor(
    private readonly selector: string,
    private readonly candidates: () => Iterable<Element>,
    private readonly original: (element: Element) => string | undefined,
  ) {}

  attach() {
    document.addEventListener("pointermove", this.onMove, { capture: true, passive: true });
    document.addEventListener("pointerout", this.onLeave, { capture: true, passive: true });
    addEventListener("scroll", this.onScroll, { capture: true, passive: true });
  }

  detach() {
    document.removeEventListener("pointermove", this.onMove, true);
    document.removeEventListener("pointerout", this.onLeave, true);
    removeEventListener("scroll", this.onScroll, true);
    if (this.frame !== undefined) cancelAnimationFrame(this.frame);
    this.hide();
    this.host?.remove();
    this.host = undefined;
    this.box = undefined;
  }

  private move(event: PointerEvent) {
    if (event.pointerType === "touch") return;
    this.pointer = { x: event.clientX, y: event.clientY };
    // At most once a frame.
    if (this.frame === undefined) {
      this.frame = requestAnimationFrame(() => {
        this.frame = undefined;
        this.check();
      });
    }
  }

  private check() {
    const { x, y } = this.pointer;
    if (this.isOnPopup(x, y)) {
      clearTimeout(this.hideTimer);
      return;
    }
    const element = this.paragraphAt(x, y);
    if (!element) {
      this.pending = undefined;
      clearTimeout(this.showTimer);
      this.scheduleHide();
      return;
    }
    clearTimeout(this.hideTimer);
    if (element === this.target || element === this.pending) return;
    this.pending = element;
    clearTimeout(this.showTimer);
    // Moving from one paragraph to the next while a popup shows: follow at once.
    this.showTimer = setTimeout(() => this.show(element), this.target ? 0 : SHOW_DELAY_MS);
  }

  /** The translated paragraph at the point: from the element there, else the smallest box that holds it. */
  private paragraphAt(x: number, y: number): Element | undefined {
    const under = document.elementFromPoint(x, y)?.closest(this.selector);
    if (under && under !== this.host && this.original(under)) return under;
    let best: Element | undefined;
    let bestArea = Infinity;
    for (const element of this.candidates()) {
      const bounds = element.getBoundingClientRect();
      if (x < bounds.left || x > bounds.right || y < bounds.top || y > bounds.bottom) continue;
      for (const rect of element.getClientRects()) {
        if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue;
        const area = rect.width * rect.height;
        if (area < bestArea && this.original(element)) {
          best = element;
          bestArea = area;
        }
      }
    }
    return best;
  }

  private isOnPopup(x: number, y: number): boolean {
    if (!this.box || this.box.hidden) return false;
    const rect = this.box.getBoundingClientRect();
    return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
  }

  private scheduleHide() {
    if (!this.target) return;
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => this.hide(), HIDE_DELAY_MS);
  }

  private show(element: Element) {
    this.pending = undefined;
    const text = this.original(element);
    if (!text || !element.isConnected) return;
    this.target = element;
    const box = this.ensureBox();
    box.querySelector(".text")!.textContent = text;
    box.hidden = false;
    this.place(element.getBoundingClientRect(), box);
  }

  private hide() {
    clearTimeout(this.showTimer);
    clearTimeout(this.hideTimer);
    this.target = undefined;
    this.pending = undefined;
    if (this.box) this.box.hidden = true;
  }

  /** Below the paragraph, or above it when there is no room below; inside the window either way. */
  private place(rect: DOMRect, box: HTMLDivElement) {
    const width = Math.min(Math.max(rect.width, 260), 520, innerWidth - 2 * GAP);
    box.style.width = `${width}px`;
    box.style.left = `${Math.min(Math.max(rect.left, GAP), innerWidth - width - GAP)}px`;
    box.style.top = "0px";
    const height = box.offsetHeight;
    const below = rect.bottom + GAP;
    const above = rect.top - GAP - height;
    box.style.top = `${below + height <= innerHeight - GAP || above < GAP ? Math.min(below, innerHeight - height - GAP) : above}px`;
  }

  private ensureBox(): HTMLDivElement {
    if (this.box && this.host?.isConnected) return this.box;
    const host = document.createElement("plamonic-original");
    const shadow = host.attachShadow({ mode: "open" });
    shadow.innerHTML = `<style>
      :host { all: initial; }
      .box {
        position: fixed; z-index: 2147483647; box-sizing: border-box; max-height: 40vh; overflow: auto;
        padding: 8px 10px 9px; border-radius: 8px;
        background: #ffffff; color: #16181d; border: 1px solid rgba(0, 0, 0, .12);
        box-shadow: 0 6px 24px rgba(0, 0, 0, .18);
        font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Noto Sans JP", sans-serif;
        text-align: left; white-space: pre-wrap; user-select: text; -webkit-user-select: text;
      }
      .box[hidden] { display: none; }
      .label { display: block; margin-bottom: 3px; font-size: 11px; color: #8b919c; }
      @media (prefers-color-scheme: dark) {
        .box { background: #232429; color: #eceef2; border-color: rgba(255, 255, 255, .12); }
        .label { color: #8a909b; }
      }
    </style><div class="box" hidden role="tooltip"><span class="label">原文</span><span class="text"></span></div>`;
    document.documentElement.append(host);
    this.host = host;
    this.box = shadow.querySelector(".box") as HTMLDivElement;
    return this.box;
  }
}
