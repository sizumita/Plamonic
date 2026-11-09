/**
 * Website settings come from the Plamonic app (Settings › Webサイト; DESIGN §9.4): for each site, whether its
 * pages are translated by themselves (automatic), when chosen in the menu (manual) or never (off), and where on
 * the page.
 */
export interface SiteInfo {
  pattern: string;
  name: string;
  mode: "off" | "automatic" | "manual";
  /** CSS selectors of the parts to translate; empty = the whole page. */
  include: string[];
  exclude: string[];
  /** user, preset or defaults (the site has no settings). */
  source: string;
}

/** Access to every site: then the app alone decides which sites are translated by themselves. */
export const ALL_SITES = ["*://*/*"];

/**
 * The browser's match patterns for a site pattern (`host[/path]`, `*.` for a domain with its subdomains). Chrome's
 * `*.` takes in the domain itself too.
 */
export function matchPatterns(pattern: string): string[] {
  let text = pattern.trim().toLowerCase().replace(/^[a-z]+:\/\//, "");
  const slash = text.indexOf("/");
  const host = slash < 0 ? text : text.slice(0, slash);
  const path = slash < 0 ? "/" : text.slice(slash);
  if (!/^(\*\.)?[a-z0-9.-]+$/.test(host)) return [];
  text = `*://${host}${path.endsWith("*") ? path : `${path}*`}`;
  return [text];
}

/** The pattern to ask for permission with: the whole origin of the site (permissions are per origin). */
export function originPatterns(pattern: string): string[] {
  return matchPatterns(pattern).map((match) => match.replace(/^(\*:\/\/[^/]+)\/.*$/, "$1/*"));
}

/**
 * The selectors that are valid CSS; an invalid one (a typo in the settings) is left out instead of breaking the
 * page translation.
 */
export function validSelectors(selectors: string[], probe: (selector: string) => void): string[] {
  return selectors.filter((selector) => {
    try {
      probe(selector);
      return true;
    } catch {
      return false;
    }
  });
}
