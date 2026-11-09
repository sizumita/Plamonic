import { BROWSER, ext } from "../shared/api";
import type { BackgroundMessage, BackgroundReply } from "../shared/messages";
import { NativeBridge } from "./native-bridge";
import { refreshAutomaticSites } from "./automatic-sites";

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
      return openSidePanel(sender.tab?.id);
    case "site:get":
      return bridge.call({ type: "site", url: message.url }).then((response) => response.site);
    case "sites:refresh":
      return refreshAutomaticSites(bridge, true);
    case "site:set":
      return bridge.call({ type: "setSite", url: message.url, mode: message.mode }).then(async (response) => {
        await refreshAutomaticSites(bridge, true);
        return response.site;
      });
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

/**
 * Chrome's side panel for one tab, opened from a click in the page (the player's Plamonic button). The panel
 * belongs to that tab: it hides on other tabs and shows that tab's feature.
 */
async function openSidePanel(tabId: number | undefined): Promise<{ ok: boolean; error?: string }> {
  if (tabId === undefined || !ext.sidePanel) return { ok: false, error: "no side panel" };
  try {
    // open() needs the click: start it before anything is awaited.
    void ext.sidePanel.setOptions({ tabId, path: `sidebar.html?tab=${tabId}`, enabled: true });
    await ext.sidePanel.open({ tabId });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: String((error as Error)?.message ?? error) };
  }
}

// The toolbar button opens the menu (popup). Chrome's side panel is opened per tab from there (or the page), so
// it is off everywhere else. Chrome remembers the panel behavior across updates: an earlier version made the
// button open the panel, so it is turned off explicitly.
if (BROWSER === "chrome" && ext.sidePanel) {
  ext.sidePanel.setPanelBehavior({ openPanelOnActionClick: false }).catch(() => {});
  ext.sidePanel.setOptions({ enabled: false }).catch(() => {});
}

// Sites set to automatic in the app change rarely; read them again when the worker starts (at most once a minute).
void refreshAutomaticSites(bridge);
