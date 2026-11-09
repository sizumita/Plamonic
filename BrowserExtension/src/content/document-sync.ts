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
  document: string;
  kind: "captions" | "page";
  items: SyncItem[];
  context?: string;
  sourceLanguage?: string;
  /** Texts from the focus that the app should translate before anything else. */
  urgent?: number;
  /** Called after results or the status changed. */
  onChange: () => void;
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
  private sentItems = false;
  private stopped = false;
  private wake: (() => void) | undefined;
  private readonly index = new Map<string, number>();

  constructor(
    private readonly context: FeatureContext,
    private readonly options: SyncOptions,
  ) {
    options.items.forEach((item, position) => this.index.set(item.id, position));
  }

  start() {
    void this.loop();
  }

  stop() {
    this.stopped = true;
    this.wake?.();
    if (this.sentItems) void this.context.bridge({ type: "close", document: this.options.document });
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
    const { document, kind, items, context, sourceLanguage, urgent } = this.options;
    const response = await this.context.bridge({
      type: "sync",
      document,
      kind,
      items: this.sentItems ? undefined : items,
      focus: this.focus,
      urgent: urgent ?? 3,
      want: this.wanted(),
      context,
      sourceLanguage,
    });
    if (this.stopped) return 0;
    if (!response.ok) {
      switch (response.error) {
        case "unknownDocument":
          // The app restarted or forgot the document: send the texts again right away.
          this.sentItems = false;
          return 0;
        case "disabled":
          this.setStatus({ state: "disabled", message: response.message ?? "" });
          return 5000;
        case "appNotRunning":
        case "unreachable":
          this.sentItems = false;
          this.setStatus({ state: "unreachable", message: response.message ?? "" });
          return 5000;
        default:
          this.setStatus({ state: "error", message: response.message ?? String(response.error) });
          return 10000;
      }
    }
    this.sentItems = true;
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
    if (this.unsettled(this.focusIndex(), LOOKAHEAD).length > 0) return 700;
    if (this.progress.done < this.progress.total) return 2000;
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

  /** Ids whose results may still change: near the focus first, then the rest ahead of it. */
  private wanted(): string[] {
    const from = Math.max(0, this.focusIndex() - 2);
    return this.unsettled(from, MAX_WANT);
  }

  private unsettled(from: number, limit: number): string[] {
    const ids: string[] = [];
    const items = this.options.items;
    for (let position = from; position < items.length && ids.length < limit; position++) {
      const state = this.results.get(items[position]!.id)?.state;
      if (state !== "final" && state !== "skipped" && state !== "failed") ids.push(items[position]!.id);
    }
    return ids;
  }
}
