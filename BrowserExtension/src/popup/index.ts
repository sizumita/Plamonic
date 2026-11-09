import { INJECTABLE_ACTIONS, type ActionIcon, type PageAction, type PageActions } from "../shared/actions";
import { BROWSER, ext, sendRuntime } from "../shared/api";
import type { BridgeStatus } from "../shared/bridge-types";
import { TOGGLE_SIDEBAR_EVENT, type BackgroundMessage, type ContentMessage } from "../shared/messages";
import { ALL_SITES, originPatterns, type SiteInfo } from "../shared/sites";
import STYLE from "./style.css";

/**
 * The toolbar menu: what Plamonic can do on this page. The page's content script lists its actions; on a site
 * without it (anything but YouTube until asked), the menu offers what can be injected, such as translating the
 * page. The sidebar is one of the items, on pages that have something for it.
 */
const style = document.createElement("style");
style.textContent = STYLE;
document.head.append(style);

const ICONS: Record<ActionIcon, string> = {
  translate: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 5h9M8.5 3v2M6 5c.6 3.4 2.6 6 5.5 7.5M11 5c-.7 3.6-3 6.6-6.5 8.5"/><path d="M13 21l4-9 4 9M14.5 18h5"/></svg>`,
  restore: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.3-5.6M4 4v4h4"/></svg>`,
  sidebar: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M15 4v16"/></svg>`,
  captions: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M10 10.5a2 2 0 1 0 0 3M17 10.5a2 2 0 1 0 0 3"/></svg>`,
  automatic: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M13 3L5 13.5h6L10 21l8-10.5h-6L13 3z"/></svg>`,
  pause: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M9 6v12M15 6v12"/></svg>`,
  resume: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M8 5.5v13l10.5-6.5L8 5.5z"/></svg>`,
};

let tabID: number | undefined;
/** Whether the page has the content script (else the actions inject it). */
let hasContent = false;
let site: SiteInfo | undefined;
/** The extension may run on this site by itself (needed for automatic translation). */
let siteAllowed = true;

async function ask(message: ContentMessage): Promise<PageActions | undefined> {
  if (tabID === undefined) return undefined;
  try {
    return (await ext.tabs.sendMessage(tabID, message)) as PageActions | undefined;
  } catch {
    return undefined;
  }
}

async function load() {
  const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  tabID = tab?.id;
  const status = sendRuntime<BridgeStatus>({ type: "bridge:status", refresh: true } satisfies BackgroundMessage);
  const web = !tab?.url || /^https?:/.test(tab.url);
  if (web && tab?.url) {
    site = await sendRuntime<SiteInfo>({ type: "site:get", url: tab.url } satisfies BackgroundMessage);
    if (site?.mode === "automatic") {
      try {
        siteAllowed = await ext.permissions.contains({ origins: originPatterns(site.pattern) });
      } catch {}
    }
  }
  let actions = await ask({ type: "page:actions" });
  hasContent = actions !== undefined;
  if (!actions && web) {
    const injectable = site?.mode === "off" ? [] : INJECTABLE_ACTIONS;
    actions = { actions: injectable, sidebar: { available: false } };
  }
  render(actions, await status);
}

function render(actions: PageActions | undefined, status: BridgeStatus | undefined) {
  const items: HTMLElement[] = [];
  const problem = notice(status);
  if (problem) items.push(problem);
  if (site) items.push(siteLine(site));
  if (site?.mode === "automatic" && !siteAllowed) {
    items.push(
      button(
        {
          id: "allow-all",
          kind: "button",
          label: "すべてのサイトで自動翻訳を使う",
          detail: "以後は Plamonic の設定で「自動」にしたサイトが、開くだけで訳されます",
          icon: "translate",
        },
        () => allow(ALL_SITES),
      ),
      button(
        {
          id: "allow-site",
          kind: "button",
          label: "このサイトだけ許可",
          detail: "Plamonic の設定で「自動」です。このサイトだけ拡張機能を入れます",
          icon: "translate",
        },
        () => allow(originPatterns(site!.pattern)),
      ),
    );
  }
  if (!actions || (actions.actions.length === 0 && !actions.sidebar.available)) {
    const empty = document.createElement("div");
    empty.className = "empty";
    empty.textContent = "このページでは使えません";
    items.push(empty);
  } else {
    const buttons = actions.actions.filter((action) => action.kind === "button");
    const choices = actions.actions.filter((action) => action.kind === "choice");
    for (const action of buttons) items.push(button(action));
    if (site && site.mode !== "automatic") {
      items.push(
        button(
          {
            id: "automatic",
            kind: "button",
            label: "このサイトを自動で翻訳",
            detail: "Plamonic の設定で、このサイトを「自動」にします",
            icon: "automatic",
          },
          enableAutomatic,
        ),
      );
    }
    if (actions.sidebar.available) {
      items.push(
        button({ id: "sidebar", kind: "button", label: actions.sidebar.label ?? "サイドバーを開く", icon: "sidebar" }, openSidebar),
      );
    }
    if (choices.length && items.length) items.push(separator());
    for (const action of choices) items.push(choice(action));
  }
  document.body.replaceChildren(...items);
}

/** Which of the app's website settings apply here: Settings › Webサイト in Plamonic. */
function siteLine(info: SiteInfo): HTMLElement {
  const element = document.createElement("div");
  element.className = "site";
  const mode = { automatic: "自動", manual: "手動", off: "オフ" }[info.mode];
  const name = info.source === "defaults" ? `${info.name}（設定なし）` : info.name;
  element.textContent = `${name} ・ ${mode}`;
  element.title = "Plamonic の設定「Webサイト」で変えられます";
  return element;
}

/**
 * Lets the extension run by itself on `origins` (this site, or every site), so pages of sites set to 自動 open
 * translated. The permission prompt needs the click, so it is asked before anything is awaited.
 */
async function allow(origins: string[]) {
  if (!site) return;
  const request = ext.permissions.request({ origins });
  let granted = false;
  try {
    granted = await request;
  } catch (error) {
    showError(String((error as Error)?.message ?? error));
    return;
  }
  if (!granted) return;
  await sendRuntime({ type: "sites:refresh" } satisfies BackgroundMessage);
  // This page too, without reloading it.
  await perform("start:page-translation");
}

/**
 * Sets this site to 自動 in the app's settings, lets the extension run on sites by itself (asked once, for every
 * site, so the app alone decides from now on), and translates this page now. The permission prompt needs the click,
 * so it is asked before anything is awaited; declining it still sets the site (the menu then offers this site alone).
 */
async function enableAutomatic() {
  if (!site || tabID === undefined) return;
  const request = ext.permissions.request({ origins: ALL_SITES }).catch(() => false);
  await request;
  const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
  const updated = await sendRuntime<SiteInfo>({ type: "site:set", url: tab?.url ?? "", mode: "automatic" } satisfies BackgroundMessage);
  if (!updated) {
    showError("Plamonic の設定を変えられませんでした。Plamonic が起動しているか確かめてください。");
    return;
  }
  site = updated;
  const running = (await ask({ type: "page:actions" }))?.actions.some((action) => action.id.startsWith("page-translation:"));
  if (running) window.close();
  else await perform("start:page-translation");
}

function notice(status: BridgeStatus | undefined): HTMLElement | undefined {
  let text: string | undefined;
  if (status?.state === "unreachable") text = "Plamonic が起動していません。Mac で Plamonic を起動してください。";
  else if (status?.state === "connected" && !status.enabled) text = "Plamonic の設定で「ブラウザの拡張機能に翻訳を提供する」がオフです。";
  if (!text) return undefined;
  const element = document.createElement("div");
  element.className = "notice";
  element.textContent = text;
  return element;
}

function button(action: Extract<PageAction, { kind: "button" }>, onClick?: () => Promise<void>): HTMLElement {
  const element = document.createElement("button");
  element.className = "item";
  element.innerHTML = ICONS[action.icon ?? "translate"];
  const text = document.createElement("span");
  text.className = "text";
  const label = document.createElement("span");
  label.textContent = action.label;
  text.append(label);
  if (action.detail) {
    const detail = document.createElement("span");
    detail.className = "detail";
    detail.textContent = action.detail;
    text.append(detail);
  }
  element.append(text);
  element.addEventListener("click", async () => {
    element.disabled = true;
    await (onClick ?? (() => perform(action.id)))();
  });
  return element;
}

function choice(action: Extract<PageAction, { kind: "choice" }>): HTMLElement {
  const element = document.createElement("div");
  element.className = "choice";
  const label = document.createElement("div");
  label.className = "label";
  label.textContent = action.label;
  const group = document.createElement("div");
  group.className = "segmented";
  for (const option of action.options) {
    const segment = document.createElement("button");
    segment.textContent = option.label;
    segment.setAttribute("aria-pressed", String(option.value === action.value));
    segment.addEventListener("click", async () => {
      for (const other of group.children) other.setAttribute("aria-pressed", String(other === segment));
      await ask({ type: "page:action", id: action.id, value: option.value });
    });
    group.append(segment);
  }
  element.append(label, group);
  return element;
}

function separator(): HTMLElement {
  const element = document.createElement("div");
  element.className = "separator";
  return element;
}

/** Runs an action in the page, injecting the content script first where it is not loaded. */
async function perform(id: string) {
  if (tabID === undefined) return;
  if (!hasContent) {
    try {
      await ext.scripting.executeScript({ target: { tabId: tabID }, files: ["content.js"] });
      hasContent = true;
    } catch (error) {
      showError(`このページには入れません: ${String((error as Error)?.message ?? error)}`);
      return;
    }
  }
  await ask({ type: "page:action", id });
  window.close();
}

/** Chrome: the side panel of this tab. Safari: the sidebar inside the page. */
async function openSidebar() {
  if (tabID === undefined) return;
  if (BROWSER === "chrome" && ext.sidePanel) {
    // open() needs the click: start it before anything is awaited.
    void ext.sidePanel.setOptions({ tabId: tabID, path: `sidebar.html?tab=${tabID}`, enabled: true });
    try {
      await ext.sidePanel.open({ tabId: tabID });
    } catch (error) {
      showError(String((error as Error)?.message ?? error));
      return;
    }
  } else {
    const reply = (await ask({ type: "sidebar:toggle" })) as { ok?: boolean } | undefined;
    if (!reply?.ok) {
      await ext.scripting
        .executeScript({
          target: { tabId: tabID },
          func: (name: string) => void window.dispatchEvent(new CustomEvent(name)),
          args: [TOGGLE_SIDEBAR_EVENT],
        })
        .catch(() => {});
    }
  }
  window.close();
}

function showError(text: string) {
  const element = document.createElement("div");
  element.className = "notice";
  element.textContent = text;
  document.body.prepend(element);
}

void load();
