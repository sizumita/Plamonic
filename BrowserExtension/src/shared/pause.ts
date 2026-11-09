import { ext } from "./api";

/**
 * Sites whose automatic translation the user paused from the toolbar menu (by site pattern). The app's setting
 * stays 自動; the pause belongs to this browser and lasts until 再開.
 */
const KEY = "pausedSites";

async function paused(): Promise<string[]> {
  try {
    const value = (await ext.storage.local.get(KEY))[KEY];
    return Array.isArray(value) ? (value as string[]) : [];
  } catch {
    return [];
  }
}

export async function isPaused(pattern: string): Promise<boolean> {
  return (await paused()).includes(pattern);
}

export async function setPaused(pattern: string, value: boolean): Promise<void> {
  const list = (await paused()).filter((item) => item !== pattern);
  if (value) list.push(pattern);
  try {
    await ext.storage.local.set({ [KEY]: list });
  } catch {}
}
