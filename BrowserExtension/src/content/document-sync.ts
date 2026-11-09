import type { BridgeResult } from "../shared/bridge-types";
import type { FeatureContext } from "./feature";

/**
 * Keeps one "document" (DESIGN §9) in step with the app: sends its texts once, moves its focus as the user
 * moves through it, and polls for results until every text near the focus is final. Any feature that translates
 * a list of texts uses it (captions now; page paragraphs later).
 */
export interface SyncItem {
  id: string;
  text: string;
}

export interface SyncOptions {
  /**
   * What the document is (a video's track, a page's address). Each DocumentSync adds its own suffix, so two tabs
   * on the same page are two documents in the app: their texts and ids may differ.
   */
  document: string;
  kind: "captions" | "page";
  items: SyncItem[];
  context?: string;
  sourceLanguage?: string;
  /** Texts from the focus that the app should translate before anything else. */
  urgent?: number;
  /** Called after results or the status changed. */
  onChange: () => void;
  /** The page, so its site's settings in the app apply (target language, context). */
  url?: string;
}

export type SyncStatus =
  | { state: "connecting" }
  | { state: "ok" }
  | { state: "unreachable"; message: string }
  | { state: "disabled"; message: string }
  | { state: "error"; message: string };

/** Texts after the focus whose results are asked for in every poll. */
const LOOKAHEAD = 60;
/** At most this many result ids per poll. */
const MAX_WANT = 200;

export class DocumentSync {
  readonly results = new Map<string, BridgeResult>();
  status: SyncStatus = { state: "connecting" };
  progress = { done: 0, total: 0 };

  private focus: string | undefined;
  private visible: string[] = [];
  /** Bumped when the texts change; the app has the texts when `sentRevision` is the current one. */
  private itemsRevision = 0;
  private sentRevision = -1;
  private stopped = false;
  private wake: (() => void) | undefined;
  private readonly index = new Map<string, number>();

  private readonly options: SyncOptions;
  /** The document's id in the app: `options.document` and this instance's suffix (within the app's 512). */
  private readonly documentId: string;

  constructor(
    private readonly context: FeatureContext,
    options: SyncOptions,
  ) {
    this.options = { ...options };
    this.documentId = `${options.document.slice(0, 490)}#${instanceSuffix()}`;
    options.items.forEach((item, position) => this.index.set(item.id, position));
  }

  start() {
    void this.loop();
  }

  stop() {
    this.stopped = true;
    this.wake?.();
    if (this.sentRevision >= 0) void this.context.bridge({ type: "close", document: this.documentId });
  }

  /** The item being shown (or about to be). Polls right away when it moved. */
  setFocus(id: string | undefined) {
    if (id === this.focus) return;
    this.focus = id;
    this.wake?.();
  }

  /** Asks again now, such as after the app was started. */
  retry() {
    this.wake?.();
  }

  /** Replaces the texts (a page that grew). They are sent again with the next request; known results stay. */
  setItems(items: SyncItem[]) {
    this.options.items = items;
    this.index.clear();
    items.forEach((item, position) => this.index.set(item.id, position));
    this.itemsRevision++;
    this.wake?.();
  }

  /**
   * The items on screen, top to bottom (a page). The app translates them first, whatever their place in the list;
   * the first one is the focus. Asks right away when they changed.
   */
  setVisible(ids: string[]) {
    if (ids.length === this.visible.length && ids.every((id, index) => id === this.visible[index])) return;
    this.visible = ids;
    this.focus = ids[0] ?? this.focus;
    this.wake?.();
  }

  private async loop() {
    while (!this.stopped) {
      const delay = await this.poll();
      if (this.stopped) return;
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, delay);
        this.wake = () => {
          clearTimeout(timer);
          resolve();
        };
      });
      this.wake = undefined;
    }
  }

  /** One request; returns how long to wait before the next. */
  private async poll(): Promise<number> {
    const { kind, items, context, sourceLanguage, urgent } = this.options;
    // Texts that change while this request is out are sent with the next one (the revision still differs then).
    const revision = this.itemsRevision;
    const response = await this.context.bridge({
      type: "sync",
      document: this.documentId,
      kind,
      items: this.sentRevision === revision ? undefined : items,
      focus: this.focus,
      urgent: urgent ?? 3,
      visible: this.visible.length ? this.visible.slice(0, 60) : undefined,
      want: this.wanted(),
      context,
      sourceLanguage,
      url: this.options.url,
    });
    if (this.stopped) return 0;
    if (!response.ok) {
      switch (response.error) {
        case "unknownDocument":
          // The app restarted or forgot the document: send the texts again right away.
          this.sentRevision = -1;
          return 0;
        case "disabled":
          this.setStatus({ state: "disabled", message: response.message ?? "" });
          return 5000;
        case "appNotRunning":
        case "unreachable":
          this.sentRevision = -1;
          this.setStatus({ state: "unreachable", message: response.message ?? "" });
          return 5000;
        default:
          this.setStatus({ state: "error", message: response.message ?? String(response.error) });
          return 10000;
      }
    }
    this.sentRevision = Math.max(this.sentRevision, revision);
    let changed = this.status.state !== "ok";
    this.status = { state: "ok" };
    for (const result of response.results ?? []) {
      const previous = this.results.get(result.id);
      if (previous?.state !== result.state || previous?.text !== result.text) {
        this.results.set(result.id, result);
        changed = true;
      }
    }
    if (response.progress && (response.progress.done !== this.progress.done || response.progress.total !== this.progress.total)) {
      this.progress = response.progress;
      changed = true;
    }
    if (changed) this.options.onChange();
    const working = (id: string) => this.results.get(id)?.state !== "failed";
    if (this.visible.some((id) => !this.isSettled(id) && working(id)) || this.unsettled(this.focusIndex(), LOOKAHEAD).some(working)) {
      return 700;
    }
    if (this.progress.done < this.progress.total) return 2000;
    // Failed texts: the app tries them again after a back-off (30 s at first), so look now and then.
    if (this.wanted().length > 0) return 10000;
    // Everything ahead is done; keep the document alive in the app (it forgets after 5 minutes).
    return 60000;
  }

  private setStatus(status: SyncStatus) {
    this.status = status;
    this.options.onChange();
  }

  private focusIndex() {
    return this.focus === undefined ? 0 : (this.index.get(this.focus) ?? 0);
  }

  /**
   * Ids whose results may still change: what is on screen, then near the focus and ahead of it; for a page, then
   * the part above too (the app reads all of it).
   */
  private wanted(): string[] {
    const ids = new Set(this.visible.filter((id) => !this.isSettled(id)));
    const from = Math.max(0, this.focusIndex() - 2);
    for (const id of this.unsettled(from, MAX_WANT)) ids.add(id);
    if (this.options.kind === "page") for (const id of this.unsettled(0, MAX_WANT)) ids.add(id);
    return [...ids].slice(0, MAX_WANT);
  }

  /** No longer changes. "failed" is not: the app retries failed texts after a back-off. */
  private isSettled(id: string) {
    const state = this.results.get(id)?.state;
    return state === "final" || state === "skipped";
  }

  private unsettled(from: number, limit: number): string[] {
    const ids: string[] = [];
    const items = this.options.items;
    for (let position = from; position < items.length && ids.length < limit; position++) {
      if (!this.isSettled(items[position]!.id)) ids.push(items[position]!.id);
    }
    return ids;
  }
}

/** A short random suffix that tells this page's document from another tab's. */
function instanceSuffix(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
