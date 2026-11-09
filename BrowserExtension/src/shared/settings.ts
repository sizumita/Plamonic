import { ext } from "./api";

/** The extension's own settings, shared by every part of it (storage.local). */
export interface Settings {
  /** What the video shows: the translation instead of the captions, both, or YouTube's own captions. */
  captionOverlay: "translation" | "both" | "off";
  /** The sidebar's transcript also shows the original under each line. */
  sidebarShowsOriginal: boolean;
  /** The sidebar keeps the current line in view. */
  sidebarAutoScroll: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  captionOverlay: "translation",
  sidebarShowsOriginal: true,
  sidebarAutoScroll: true,
};

const KEY = "settings";

export async function loadSettings(): Promise<Settings> {
  try {
    const stored = (await ext.storage.local.get(KEY))[KEY] as Partial<Settings> | undefined;
    return { ...DEFAULT_SETTINGS, ...stored };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

export async function updateSettings(change: Partial<Settings>): Promise<void> {
  const current = await loadSettings();
  await ext.storage.local.set({ [KEY]: { ...current, ...change } });
}

/** Calls `listener` with the new settings whenever any part of the extension changes them. */
export function onSettingsChanged(listener: (settings: Settings) => void): () => void {
  const handler = (changes: Record<string, chrome.storage.StorageChange>, area: string) => {
    if (area !== "local" || !changes[KEY]) return;
    listener({ ...DEFAULT_SETTINGS, ...(changes[KEY].newValue as Partial<Settings>) });
  };
  ext.storage.onChanged.addListener(handler);
  return () => ext.storage.onChanged.removeListener(handler);
}
