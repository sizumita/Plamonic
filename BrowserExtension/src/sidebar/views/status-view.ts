import type { ViewState } from "../../shared/messages";
import type { SidebarView } from "./view";

/** Pages without a feature (or that the extension cannot run on). */
export class StatusView implements SidebarView {
  private root: HTMLElement | undefined;

  mount(root: HTMLElement) {
    this.root = root;
  }

  update(state: ViewState) {
    if (!this.root) return;
    const box = document.createElement("div");
    box.className = "empty";
    const title = document.createElement("h2");
    const text = document.createElement("p");
    if (state.kind === "unavailable") {
      title.textContent = "このページでは使えません";
      text.textContent = "Plamonic の拡張機能はこのページに入れません。";
    } else {
      title.textContent = "このページで使える機能はありません";
      text.textContent = "YouTube の動画を開くと、字幕の翻訳がここに表示されます。";
    }
    box.append(title, text);
    this.root.replaceChildren(box);
  }
}
