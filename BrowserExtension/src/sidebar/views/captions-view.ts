import type { ViewState } from "../../shared/messages";
import { DEFAULT_SETTINGS, loadSettings, onSettingsChanged, updateSettings, type Settings } from "../../shared/settings";
import type { CaptionLine, CaptionsTick, CaptionsViewState } from "../../features/youtube/view";
import type { SidebarView, ViewEnvironment } from "./view";

/** After the user scrolls the transcript, it stops following playback for this long (or until "現在の位置へ"). */
const MANUAL_SCROLL_MS = 8000;

/**
 * The transcript of the video's captions: each line with its time, translation and original. The line being
 * shown is highlighted and kept in view; clicking a line seeks there.
 */
export class CaptionsView implements SidebarView {
  private root!: HTMLElement;
  private settings: Settings = { ...DEFAULT_SETTINGS };
  private header!: HTMLElement;
  private notice!: HTMLElement;
  private controls!: HTMLElement;
  private list!: HTMLElement;
  private follow!: HTMLButtonElement;
  private progress!: HTMLElement;
  private rows = new Map<string, HTMLElement>();
  private order: string[] = [];
  private activeId: string | undefined;
  private manualScrollUntil = 0;
  private programmaticScroll = false;
  private unsubscribe: (() => void) | undefined;

  constructor(private readonly environment: ViewEnvironment) {}

  mount(root: HTMLElement) {
    this.root = root;
    this.header = element("div", "video");
    this.notice = element("div", "notice");
    this.notice.hidden = true;
    this.controls = element("div", "controls");
    this.list = element("div", "transcript");
    this.follow = element("button", "follow") as HTMLButtonElement;
    this.follow.textContent = "現在の位置へ";
    this.follow.hidden = true;
    this.follow.addEventListener("click", () => {
      this.manualScrollUntil = 0;
      this.follow.hidden = true;
      this.scrollToActive("smooth");
    });
    this.progress = element("span", "progress");
    root.replaceChildren(this.header, this.notice, this.controls, this.list);
    this.list.append(this.follow);
    for (const name of ["wheel", "touchmove", "keydown"]) {
      this.list.addEventListener(name, () => this.userScrolled(), { passive: true });
    }
    this.list.addEventListener("scroll", () => {
      if (!this.programmaticScroll) this.userScrolled();
    });
    void loadSettings().then((settings) => this.applySettings(settings));
    this.unsubscribe = onSettingsChanged((settings) => this.applySettings(settings));
  }

  unmount() {
    this.unsubscribe?.();
  }

  update(raw: ViewState) {
    const state = raw as CaptionsViewState;
    this.renderHeader(state);
    this.renderNotice(state);
    this.renderLines(state.lines);
    this.progress.textContent = state.progress && state.progress.total > 0 ? `翻訳済み ${state.progress.done} / ${state.progress.total}` : "";
    this.setActive(state.activeId);
  }

  tick(raw: unknown) {
    this.setActive((raw as CaptionsTick).activeId);
  }

  // MARK: Rendering

  private renderHeader(state: CaptionsViewState) {
    const title = element("div", "title");
    title.textContent = state.title || "YouTube";
    const meta = element("div", "meta");
    const parts = [state.channel, state.track && `字幕: ${state.track.name}`].filter(Boolean);
    meta.textContent = parts.join(" ・ ");
    this.header.replaceChildren(title, meta);
  }

  private renderNotice(state: CaptionsViewState) {
    let text: string | undefined;
    let tone: "info" | "warn" | "error" = "info";
    let retry = false;
    if (state.phase === "idle") text = "動画を再生すると字幕の翻訳を始めます。";
    else if (state.phase === "loading") text = "字幕を読み込んでいます…";
    else if (state.phase === "no-captions" || state.phase === "same-language") text = state.message;
    else if (state.phase === "error") [text, tone] = [state.message ?? "字幕を読み込めませんでした", "error"];
    else if (state.bridge.state === "unreachable") [text, tone, retry] = ["Plamonic が起動していません。起動すると翻訳を始めます。", "warn", true];
    else if (state.bridge.state === "disabled") [text, tone] = ["Plamonic の設定「ブラウザの拡張機能に翻訳を提供する」がオフです。", "warn"];
    else if (state.bridge.state === "error") [text, tone, retry] = [state.bridge.message ?? "翻訳でエラーが起きました", "error", true];
    this.notice.hidden = !text;
    if (!text) return;
    this.notice.dataset.tone = tone;
    this.notice.replaceChildren(text);
    if (retry) {
      const button = document.createElement("button");
      button.textContent = "再試行";
      button.addEventListener("click", () => this.environment.command("retry"));
      this.notice.append(button);
    }
  }

  private renderControls() {
    const overlay = element("div", "segmented");
    overlay.setAttribute("role", "group");
    overlay.title = "動画の上の字幕";
    const modes: [Settings["captionOverlay"], string][] = [
      ["translation", "訳文"],
      ["both", "訳文＋原文"],
      ["off", "元の字幕"],
    ];
    for (const [mode, label] of modes) {
      const button = document.createElement("button");
      button.textContent = label;
      button.setAttribute("aria-pressed", String(this.settings.captionOverlay === mode));
      button.addEventListener("click", () => void updateSettings({ captionOverlay: mode }));
      overlay.append(button);
    }
    const original = checkbox("原文", this.settings.sidebarShowsOriginal, (value) =>
      updateSettings({ sidebarShowsOriginal: value }),
    );
    const autoScroll = checkbox("自動スクロール", this.settings.sidebarAutoScroll, (value) =>
      updateSettings({ sidebarAutoScroll: value }),
    );
    this.controls.replaceChildren(overlay, original, autoScroll, this.progress);
  }

  private renderLines(lines: CaptionLine[]) {
    const ids = lines.map((line) => line.id);
    if (ids.length !== this.order.length || ids.some((id, index) => id !== this.order[index])) {
      this.rows.clear();
      const fragment = document.createDocumentFragment();
      for (const line of lines) {
        const row = this.makeRow(line);
        this.rows.set(line.id, row);
        fragment.append(row);
      }
      this.list.replaceChildren(fragment, this.follow);
      this.order = ids;
      this.activeId = undefined;
    }
    for (const line of lines) {
      const row = this.rows.get(line.id);
      if (!row || (row.dataset.state === line.state && row.dataset.translation === (line.translation ?? ""))) continue;
      row.dataset.state = line.state;
      row.dataset.translation = line.translation ?? "";
      const translation = row.querySelector(".translation")!;
      if (line.state === "skipped") translation.textContent = line.text;
      else if (line.translation) translation.textContent = line.translation;
      else translation.textContent = line.state === "failed" ? "翻訳できませんでした" : "翻訳中…";
      (row.querySelector(".original") as HTMLElement).hidden = line.state === "skipped";
    }
  }

  private makeRow(line: CaptionLine): HTMLElement {
    const row = element("div", "line");
    row.dataset.id = line.id;
    const time = element("span", "time");
    time.textContent = formatTime(line.start);
    const translation = element("span", "translation");
    const original = element("span", "original");
    original.textContent = line.text;
    row.append(time, translation, original);
    row.addEventListener("click", () => {
      this.manualScrollUntil = 0;
      this.environment.command("seek", { time: line.start });
    });
    return row;
  }

  // MARK: Following playback

  private setActive(id: string | undefined) {
    if (id === this.activeId) return;
    if (this.activeId) this.rows.get(this.activeId)?.classList.remove("active");
    this.activeId = id;
    if (!id) return;
    this.rows.get(id)?.classList.add("active");
    if (this.settings.sidebarAutoScroll && Date.now() > this.manualScrollUntil) this.scrollToActive("smooth");
    else if (this.settings.sidebarAutoScroll) this.follow.hidden = false;
  }

  private scrollToActive(behavior: ScrollBehavior) {
    const row = this.activeId ? this.rows.get(this.activeId) : undefined;
    if (!row) return;
    this.programmaticScroll = true;
    const top = row.offsetTop - this.list.clientHeight * 0.35;
    this.list.scrollTo({ top, behavior });
    setTimeout(() => (this.programmaticScroll = false), behavior === "smooth" ? 600 : 50);
  }

  private userScrolled() {
    if (!this.settings.sidebarAutoScroll) return;
    this.manualScrollUntil = Date.now() + MANUAL_SCROLL_MS;
    this.follow.hidden = false;
    setTimeout(() => {
      if (Date.now() >= this.manualScrollUntil) this.follow.hidden = true;
    }, MANUAL_SCROLL_MS + 50);
  }

  private applySettings(settings: Settings) {
    this.settings = settings;
    this.root.classList.toggle("hide-original", !settings.sidebarShowsOriginal);
    this.renderControls();
  }
}

function element(tag: string, className: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  return node;
}

function checkbox(label: string, checked: boolean, change: (value: boolean) => unknown): HTMLElement {
  const wrapper = element("label", "toggle");
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = checked;
  input.addEventListener("change", () => void change(input.checked));
  wrapper.append(input, label);
  return wrapper;
}

export function formatTime(ms: number): string {
  const total = Math.floor(ms / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
}
