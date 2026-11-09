import { ext } from "../shared/api";
import { SIDEBAR_PORT, type ContentToSidebar, type SidebarToContent } from "../shared/messages";
import { SIDEBAR_STYLE, SidebarShell } from "./shell";

/**
 * Chrome's side panel page. It is opened for one tab (`?tab=<id>`, popup/index.ts) and shows that tab's
 * feature over a port to its content script. Without `tab`, it follows the window's active tab. (Safari's
 * sidebar lives in the page: content/embedded-sidebar.ts.)
 */
const style = document.createElement("style");
style.textContent = SIDEBAR_STYLE;
document.head.append(style);

let tabID: number | undefined;
let port: chrome.runtime.Port | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

const shell = new SidebarShell({
  command: (command, args) => send({ type: "command", command, args }),
});
document.body.append(shell.element);

function send(message: SidebarToContent) {
  try {
    port?.postMessage(message);
  } catch {}
}

/** Connects to the content script of `tab`; pages without one (or that we cannot enter) get a status view. */
function connect(tab: number | undefined) {
  clearTimeout(reconnectTimer);
  try {
    port?.disconnect();
  } catch {}
  port = undefined;
  tabID = tab;
  if (tab === undefined) return shell.show({ kind: "unavailable" });
  let connected: chrome.runtime.Port;
  try {
    connected = ext.tabs.connect(tab, { name: SIDEBAR_PORT });
  } catch {
    return shell.show({ kind: "unavailable" });
  }
  port = connected;
  let heard = false;
  connected.onMessage.addListener((message: ContentToSidebar) => {
    heard = true;
    shell.receive(message);
  });
  connected.onDisconnect.addListener(() => {
    // Read, so Chrome does not report it as unchecked: the tab has no content script (yet).
    void ext.runtime.lastError;
    if (port !== connected) return;
    port = undefined;
    // No content script on this page, or it reloaded: show the status and try again shortly.
    if (!heard) shell.show({ kind: "none" });
    reconnectTimer = setTimeout(() => connect(tabID), heard ? 500 : 3000);
  });
}

async function activeTab(): Promise<number | undefined> {
  const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  return tab?.id;
}

const fixedTab = new URLSearchParams(location.search).get("tab");
if (fixedTab) {
  connect(Number(fixedTab));
} else {
  void activeTab().then(connect);
  ext.tabs.onActivated.addListener(() => void activeTab().then(connect));
}
ext.tabs.onUpdated.addListener((id, change) => {
  if (id === tabID && change.status === "complete" && !port) connect(id);
});
