/** A short message at the top right of the page, in a shadow root so the site's styles cannot reach it. */
export function showToast(text: string, tone: "info" | "warn" | "error" = "info", duration = 4000) {
  const host = document.createElement("plamonic-toast");
  const shadow = host.attachShadow({ mode: "closed" });
  const color = tone === "error" ? "#ff8a8a" : tone === "warn" ? "#ffc773" : "#ffffff";
  shadow.innerHTML = `<style>
    :host { all: initial; position: fixed; top: 16px; right: 16px; z-index: 2147483647; }
    div { font: 13px/1.5 -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; color: ${color};
      background: rgba(20, 22, 28, .92); padding: 8px 12px; border-radius: 8px; max-width: 360px;
      box-shadow: 0 4px 16px rgba(0,0,0,.3); }
  </style><div></div>`;
  shadow.querySelector("div")!.textContent = `Plamonic: ${text}`;
  document.documentElement.append(host);
  setTimeout(() => host.remove(), duration);
}
