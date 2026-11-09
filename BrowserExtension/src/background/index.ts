import { BROWSER, ext } from "../shared/api";
import { TOGGLE_SIDEBAR_EVENT, type BackgroundMessage, type BackgroundReply, type ContentMessage } from "../shared/messages";
import { NativeBridge } from "./native-bridge";

/**
 * The background service worker: the only part that talks to the app (native messaging), and the place where
 * browser differences in opening the sidebar live.
 */
const bridge = new NativeBridge();

ext.runtime.onMessage.addListener((message: BackgroundMessage, sender, sendResponse) => {
  const reply = handle(message, sender);
  if (!reply) return false;
  reply.then(sendResponse, (error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

function handle(
  message: BackgroundMessage,
  sender: chrome.runtime.MessageSender,
): Promise<BackgroundReply[BackgroundMessage["type"]]> | undefined {
  switch (message?.type) {
    case "bridge:call":
      return bridge.call(message.request);
    case "bridge:status":
      return bridge.currentStatus(message.refresh ? 0 : 5000);
    case "tab:id":
      return Promise.resolve(sender.tab?.id);
    case "inject:main":
      return injectIntoPage(sender.tab?.id, message.file);
    case "sidebar:open":
      return openSidePanel(sender.tab?.windowId);
    default:
      return undefined;
  }
}

/** Runs one of our files in the page's own world. Safari has no "world": "MAIN" content scripts, but this API works. */
async function injectIntoPage(tabId: number | undefined, file: string): Promise<{ ok: boolean; error?: string }> {
  if (tabId === undefined) return { ok: false, error: "no tab" };
  try {
    await ext.scripting.executeScript({ target: { tabId }, files: [file], world: "MAIN", injectImmediately: true });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: String((error as Error)?.message ?? error) };
  }
}

/** Chrome's side panel, opened from a click in the page (the click counts as the user action it needs). */
async function openSidePanel(windowId: number | undefined): Promise<{ ok: boolean; error?: string }> {
  if (windowId === undefined || !ext.sidePanel) return { ok: false, error: "no side panel" };
  try {
    await ext.sidePanel.open({ windowId });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: String((error as Error)?.message ?? error) };
  }
}

// The toolbar button opens the sidebar: Chrome's side panel, or the panel the content script embeds in Safari
// (Safari has no side panel API).
if (BROWSER === "chrome") {
  ext.sidePanel?.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
} else {
  ext.action.onClicked.addListener((tab) => void toggleEmbeddedSidebar(tab.id));
}

/** Asks the content script to toggle its sidebar; if the message does not arrive, fires an event in the page. */
async function toggleEmbeddedSidebar(tabId: number | undefined) {
  if (tabId === undefined) return;
  const message: ContentMessage = { type: "sidebar:toggle" };
  let reply: { ok?: boolean } | undefined;
  try {
    reply = await ext.tabs.sendMessage(tabId, message);
  } catch {}
  if (reply?.ok) return;
  try {
    await ext.scripting.executeScript({
      target: { tabId },
      func: (name: string) => void window.dispatchEvent(new CustomEvent(name)),
      args: [TOGGLE_SIDEBAR_EVENT],
    });
  } catch {}
}
