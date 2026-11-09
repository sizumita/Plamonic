// Same file in Safari and Chrome. Collects what the page hook saw, fetches the source-language track with the
// player's PO token, sends a few cues to the app and shows every step in a small panel on the page.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const browserName = globalThis.browser && navigator.vendor.startsWith("Apple") ? "safari" : "chrome";
  let state;

  const reset = () => {
    state = { lines: [], potURL: null, fetched: false, toggles: 0, timer: null };
    log(`video ${new URL(location.href).searchParams.get("v") ?? "-"} (${browserName})`);
  };

  const panel = () => {
    let node = document.getElementById("plamonic-spike");
    if (!node && document.body) {
      node = document.createElement("pre");
      node.id = "plamonic-spike";
      node.style.cssText =
        "position:fixed;right:12px;bottom:12px;z-index:2147483647;max-width:520px;max-height:40vh;overflow:auto;" +
        "margin:0;padding:8px 10px;font:11px/1.4 ui-monospace,monospace;color:#fff;background:rgba(0,0,0,.8);" +
        "border-radius:6px;white-space:pre-wrap;pointer-events:none";
      document.body.append(node);
    }
    return node;
  };

  function log(line) {
    const stamp = new Date().toISOString().slice(11, 19);
    state?.lines.push(`${stamp} ${line}`);
    console.log("[plamonic-spike]", line);
    const node = panel();
    if (node) node.textContent = state.lines.slice(-14).join("\n");
  }

  const isWatchPage = () => location.pathname === "/watch";

  // The player only asks for captions while they are shown, and the first request after a load can go out
  // before its PO token is ready. Turn captions on, and off and on again, until a request carries pot=.
  const ensureCaptionRequest = () => {
    clearTimeout(state.timer);
    if (!isWatchPage() || state.potURL) return;
    if (state.toggles >= 4) {
      log("gave up: no caption request with pot=");
      return;
    }
    state.timer = setTimeout(() => {
      const button = document.querySelector(".ytp-subtitles-button");
      if (!button || button.offsetParent === null) {
        log("no CC button (no captions?)");
        return;
      }
      state.toggles += 1;
      if (button.getAttribute("aria-pressed") === "true") {
        button.click();
        setTimeout(() => button.click(), 300);
        log(`CC off→on (try ${state.toggles})`);
      } else {
        button.click();
        log(`CC on (try ${state.toggles})`);
      }
      ensureCaptionRequest();
    }, state.toggles === 0 ? 2500 : 4000);
  };

  const fetchSourceTrack = async (potURL) => {
    const url = new URL(potURL);
    const tracks = [
      { label: "en manual", lang: "en", kind: null },
      { label: "en asr", lang: "en", kind: "asr" },
    ];
    const cues = [];
    for (const track of tracks) {
      url.searchParams.set("lang", track.lang);
      if (track.kind) url.searchParams.set("kind", track.kind);
      else url.searchParams.delete("kind");
      url.searchParams.set("fmt", "json3");
      try {
        const text = await (await fetch(url, { credentials: "include" })).text();
        const events = text ? JSON.parse(text).events ?? [] : [];
        log(`${track.label}: ${text.length} bytes, ${events.length} events`);
        if (!cues.length) {
          for (const event of events) {
            const line = (event.segs ?? []).map((seg) => seg.utf8).join("").trim();
            if (line) cues.push({ start: event.tStartMs, text: line });
            if (cues.length >= 3) break;
          }
        }
      } catch (error) {
        log(`${track.label}: failed ${error}`);
      }
    }
    return cues;
  };

  const askApp = async (cues) => {
    const payload = { type: "translate", browser: browserName, texts: cues.map((cue) => cue.text) };
    const answer = await api.runtime.sendMessage({ type: "native", payload });
    if (!answer?.ok) {
      log(`app: error ${answer?.error} (${answer?.ms} ms)`);
      return;
    }
    log(`app: ${answer.ms} ms via ${answer.reply?.via}`);
    for (const text of answer.reply?.translations ?? []) log(`  ${text}`);
  };

  window.addEventListener("message", async (event) => {
    if (event.source !== window || event.data?.source !== "plamonic-spike") return;
    const data = event.data;
    if (data.kind === "hook-ready") {
      if (!hookReady) log("page hook ready (MAIN world)");
      hookReady = true;
      return;
    }
    if (data.kind !== "timedtext") return;
    const lang = new URL(data.url).searchParams.get("lang");
    log(`player timedtext lang=${lang} pot=${data.hasPot} ${data.length} bytes`);
    if (!data.hasPot || state.fetched) return;
    state.potURL = data.url;
    state.fetched = true;
    clearTimeout(state.timer);
    const cues = await fetchSourceTrack(data.url);
    if (cues.length) await askApp(cues);
    else log("no cues to send");
  });

  // YouTube changes videos without loading a new page.
  document.addEventListener("yt-navigate-finish", () => {
    reset();
    ensureCaptionRequest();
  });

  // Safari has no "world": "MAIN" content scripts, so both browsers load the hook into the page with a script
  // element. It has to run before the player asks for captions; the CC retries cover a late load.
  reset();
  let hookReady = false;
  document.addEventListener("securitypolicyviolation", (event) =>
    log(`CSP blocked ${event.blockedURI} (${event.violatedDirective})`));
  const hook = document.createElement("script");
  hook.src = api.runtime.getURL("page-hook.js");
  hook.onload = () => hook.remove();
  hook.onerror = () => log("script tag: page-hook.js failed to load");
  (document.head ?? document.documentElement).append(hook);
  // Fallback: ask the background page to run the hook in the MAIN world with the scripting API.
  setTimeout(async () => {
    if (hookReady) return;
    log("no hook-ready from script tag; trying scripting.executeScript MAIN");
    const answer = await api.runtime.sendMessage({ type: "inject-main" });
    log(`executeScript: ${answer?.ok ? "ok" : `error ${answer?.error}`}`);
  }, 1500);
  window.addEventListener("DOMContentLoaded", () => {
    panel();
    ensureCaptionRequest();
  });
})();
