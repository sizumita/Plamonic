import type { Settings } from "../../shared/settings";

/**
 * The translated caption drawn over the video, inside YouTube's player element so it stays in place in
 * theater mode and full screen. While it shows, YouTube's own captions are hidden.
 */
export interface OverlayLine {
  translation: string;
  original: string;
  /** No translation yet: the original is shown dimmed. */
  pending: boolean;
}

const STYLE_ID = "plamonic-youtube-style";
const ACTIVE_CLASS = "plamonic-captions-active";

const CSS = `
.${ACTIVE_CLASS} .ytp-caption-window-container { display: none !important; }
.plamonic-caption {
  position: absolute; left: 50%; bottom: 4%; transform: translateX(-50%);
  max-width: 82%; z-index: 59; pointer-events: none; text-align: center;
  display: flex; flex-direction: column; align-items: center; gap: .2em;
  font-family: "YouTube Noto", Roboto, "Hiragino Sans", "Noto Sans JP", sans-serif;
  font-size: var(--plamonic-font, 22px); line-height: 1.35;
  transition: bottom .2s ease;
}
.html5-video-player:not(.ytp-autohide) .plamonic-caption { bottom: max(4%, 64px); }
.plamonic-caption[hidden] { display: none; }
.plamonic-caption span {
  background: rgba(8, 8, 8, .75); color: #fff; padding: .08em .35em; border-radius: .15em;
  white-space: pre-wrap; box-decoration-break: clone; -webkit-box-decoration-break: clone;
}
.plamonic-caption .original { font-size: .72em; color: #e6e6e6; }
.plamonic-caption .pending { color: #cfcfcf; font-style: italic; }
.plamonic-player-button { display: inline-flex !important; align-items: center; justify-content: center; }
.plamonic-player-button svg { width: 60%; height: 60%; }
`;

/** Adds the Plamonic button next to YouTube's captions button (once; YouTube may rebuild its controls). */
export function ensurePlayerButton(player: HTMLElement, onClick: () => void) {
  if (player.querySelector(".plamonic-player-button")) return;
  const controls = player.querySelector(".ytp-right-controls");
  if (!controls) return;
  ensureStyle();
  const button = document.createElement("button");
  button.className = "ytp-button plamonic-player-button";
  button.title = "Plamonic（字幕の翻訳）";
  button.setAttribute("aria-label", button.title);
  button.innerHTML = `<svg viewBox="0 0 1024 1024" aria-hidden="true"><path fill="#fff" d="M362 214 H662 A176 176 0 0 1 838 390 V546 A176 176 0 0 1 662 722 H488 C444 772 372 818 280 838 C318 796 338 756 344 721 A176 176 0 0 1 186 546 V390 A176 176 0 0 1 362 214 Z"/><path fill="none" stroke="#3444E3" stroke-width="80" stroke-linecap="round" stroke-linejoin="round" d="M427 606 V340 H514 A94 94 0 0 1 514 528 H427"/></svg>`;
  button.addEventListener("click", (event) => {
    event.stopPropagation();
    onClick();
  });
  // Next to the captions button, which newer players nest inside a group of the controls.
  const captions = controls.querySelector(".ytp-subtitles-button");
  if (captions?.parentElement) captions.parentElement.insertBefore(button, captions);
  else controls.prepend(button);
}

function ensureStyle() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = CSS;
  document.head.append(style);
}

export class CaptionOverlay {
  private element: HTMLDivElement | undefined;
  private player: HTMLElement | undefined;
  private resize: ResizeObserver | undefined;
  private mode: Settings["captionOverlay"] = "off";
  private line: OverlayLine | null = null;

  attach(player: HTMLElement) {
    if (this.player === player && this.element?.isConnected) return;
    this.detach();
    ensureStyle();
    this.player = player;
    this.element = document.createElement("div");
    this.element.className = "plamonic-caption";
    this.element.hidden = true;
    player.append(this.element);
    this.resize = new ResizeObserver(() => this.fitFont());
    this.resize.observe(player);
    this.fitFont();
    this.applyMode();
    this.render();
  }

  detach() {
    this.resize?.disconnect();
    this.element?.remove();
    this.player?.classList.remove(ACTIVE_CLASS);
    this.element = undefined;
    this.player = undefined;
  }

  setMode(mode: Settings["captionOverlay"]) {
    this.mode = mode;
    this.applyMode();
    this.render();
  }

  show(line: OverlayLine | null) {
    this.line = line;
    this.render();
  }

  private applyMode() {
    this.player?.classList.toggle(ACTIVE_CLASS, this.mode !== "off");
  }

  private render() {
    const element = this.element;
    if (!element) return;
    const line = this.line;
    if (!line || this.mode === "off") {
      element.hidden = true;
      return;
    }
    const parts: HTMLSpanElement[] = [];
    if (line.pending) {
      parts.push(span(line.original, "pending"));
    } else {
      parts.push(span(line.translation, "translation"));
      if (this.mode === "both" && line.original) parts.push(span(line.original, "original"));
    }
    element.replaceChildren(...parts);
    element.hidden = false;
  }

  /** About the size YouTube uses for its captions at this player height. */
  private fitFont() {
    if (!this.player || !this.element) return;
    const height = this.player.clientHeight || 360;
    const size = Math.round(Math.min(Math.max(height * 0.042, 14), 44));
    this.element.style.setProperty("--plamonic-font", `${size}px`);
  }
}

function span(text: string, className: string): HTMLSpanElement {
  const element = document.createElement("span");
  element.className = className;
  element.textContent = text;
  return element;
}
