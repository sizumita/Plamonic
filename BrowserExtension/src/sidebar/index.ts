import { ext } from "../shared/api";
import { SIDEBAR_PORT, type ContentToSidebar, type SidebarToContent } from "../shared/messages";
import { SIDEBAR_STYLE, SidebarShell } from "./shell";

/**
 * Chrome's side panel page. The panel stays open across tabs, so it follows the window's active tab, connects
 * to that tab's content script over a port and shows its feature's view. (Safari's sidebar lives in the page:
 * content/embedded-sidebar.ts.)
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

void activeTab().then(connect);
ext.tabs.onActivated.addListener(() => void activeTab().then(connect));
ext.tabs.onUpdated.addListener((id, change) => {
  if (id === tabID && change.status === "complete" && !port) connect(id);
});
