/**
 * What the toolbar menu (popup) offers for the page it was opened on. The content script collects them from the
 * page's features; the popup draws them and sends the chosen one back. A page without the content script (a site
 * it does not run on by itself, until asked) gets the actions in `INJECTABLE_ACTIONS`, which inject it first.
 */
export type ActionIcon = "translate" | "restore" | "sidebar" | "captions" | "automatic" | "pause" | "resume";

export type PageAction =
  | { id: string; kind: "button"; label: string; detail?: string; icon?: ActionIcon }
  | { id: string; kind: "choice"; label: string; value: string; options: { value: string; label: string }[] };

export interface PageActions {
  actions: PageAction[];
  /** The page has a sidebar view to open. */
  sidebar: { available: boolean; label?: string };
}

/** Actions that start a feature which is not running yet: `start:<feature id>`. */
export const startAction = (featureID: string) => `start:${featureID}`;
/** Starts a feature paused on an automatic site and lifts the pause: `resume:<feature id>`. */
export const resumeAction = (featureID: string) => `resume:${featureID}`;

/** Offered on any web page without the content script; choosing one injects it. */
export const INJECTABLE_ACTIONS: PageAction[] = [
  { id: startAction("page-translation"), kind: "button", label: "このページを翻訳", icon: "translate" },
];
