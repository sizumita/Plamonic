// Same file in Safari and Chrome. Safari ignores the application ID and talks to the extension's own app;
// Chrome looks the name up in NativeMessagingHosts.
const api = globalThis.browser ?? globalThis.chrome;
const NATIVE_HOST = "io.smdr.plamonic.spike";

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "inject-main") {
    api.scripting
      .executeScript({ target: { tabId: sender.tab.id }, files: ["page-hook.js"], world: "MAIN", injectImmediately: true })
      .then(() => sendResponse({ ok: true }))
      .catch((error) => sendResponse({ ok: false, error: String(error?.message ?? error) }));
    return true;
  }
  if (message?.type !== "native") return false;
  const started = Date.now();
  api.runtime
    .sendNativeMessage(NATIVE_HOST, message.payload)
    .then((reply) => sendResponse({ ok: true, reply, ms: Date.now() - started }))
    .catch((error) => sendResponse({ ok: false, error: String(error?.message ?? error), ms: Date.now() - started }));
  return true;
});
