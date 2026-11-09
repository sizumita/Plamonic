import { ext } from "../shared/api";
import { ALL_SITES, matchPatterns, originPatterns } from "../shared/sites";
import type { NativeBridge } from "./native-bridge";

const SCRIPT_ID = "plamonic-automatic-sites";
let lastRefresh = 0;

/**
 * Runs the content script where pages may have to be translated by themselves (sites set to 自動 in the app,
 * Settings › Webサイト). The content script asks the app for the page's settings and starts translating when they
 * say so.
 *
 * - With access to every site (the toolbar menu offers it once), it runs on every page, so a site the user sets to
 *   自動 in the app is translated from its next page load on, with nothing to do in the browser.
 * - Otherwise, on the automatic sites the user allowed one by one.
 *
 * Returns the match patterns it runs on.
 */
export async function refreshAutomaticSites(bridge: NativeBridge, force = false): Promise<{ registered: string[] }> {
  if (!force && Date.now() - lastRefresh < 60_000) return { registered: [] };
  lastRefresh = Date.now();
  let matches: string[] = [];
  if (await allowed(ALL_SITES)) {
    matches = ALL_SITES;
  } else {
    const response = await bridge.call({ type: "sites" });
    // The app is not running: keep what is registered.
    if (!response.ok) return { registered: [] };
    for (const site of response.sites ?? []) {
      const patterns = matchPatterns(site.pattern);
      if (patterns.length && (await allowed(originPatterns(site.pattern)))) matches.push(...patterns);
    }
  }
  try {
    await ext.scripting.unregisterContentScripts({ ids: [SCRIPT_ID] });
  } catch {}
  if (matches.length > 0) {
    try {
      await ext.scripting.registerContentScripts([
        { id: SCRIPT_ID, matches, js: ["content.js"], runAt: "document_idle", persistAcrossSessions: true },
      ]);
    } catch {
      return { registered: [] };
    }
  }
  return { registered: matches };
}

async function allowed(origins: string[]): Promise<boolean> {
  try {
    return await ext.permissions.contains({ origins });
  } catch {
    return false;
  }
}
