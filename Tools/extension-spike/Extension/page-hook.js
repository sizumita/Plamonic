// Runs in the page's own world (MAIN) at document_start, so it wraps XHR and fetch before the player uses them.
// It reports every caption request the player makes; only the player can attach a PO token (pot=) to it.
(() => {
  if (window.__plamonicSpikeHook) return;
  window.__plamonicSpikeHook = true;

  const post = (data) => window.postMessage({ source: "plamonic-spike", ...data }, location.origin);

  const report = (url, text) => {
    if (!String(url).includes("/api/timedtext")) return;
    const absolute = new URL(url, location.href);
    let events = null;
    try {
      events = JSON.parse(text).events?.length ?? null;
    } catch {}
    post({
      kind: "timedtext",
      url: absolute.href,
      hasPot: absolute.searchParams.has("pot"),
      length: text.length,
      events,
    });
  };

  const open = XMLHttpRequest.prototype.open;
  const send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__plamonicURL = String(url);
    return open.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener("load", () => {
      if (!this.__plamonicURL?.includes("/api/timedtext")) return;
      let text = "";
      try {
        text = typeof this.response === "string" ? this.response : this.responseText ?? "";
      } catch {}
      report(this.__plamonicURL, text);
    });
    return send.apply(this, arguments);
  };

  const originalFetch = window.fetch;
  window.fetch = async function (input) {
    const response = await originalFetch.apply(this, arguments);
    try {
      const url = typeof input === "string" ? input : input?.url;
      if (url?.includes("/api/timedtext")) response.clone().text().then((text) => report(url, text));
    } catch {}
    return response;
  };

  // Again once the DOM is ready: the content script may not be listening yet at document_start.
  post({ kind: "hook-ready" });
  window.addEventListener("DOMContentLoaded", () => post({ kind: "hook-ready" }));
})();
