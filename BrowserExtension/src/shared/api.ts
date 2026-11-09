/**
 * The WebExtension API of whichever browser runs us. Safari has both `browser` and `chrome`; Chrome only
 * `chrome`. Both are promise-based in Manifest V3, so the code uses the `chrome` typings for both.
 */
const scope = globalThis as { browser?: typeof chrome; chrome?: typeof chrome };
export const ext: typeof chrome = (scope.browser ?? scope.chrome) as typeof chrome;

export const BROWSER = __BROWSER__;
export const VERSION = __VERSION__;

/** Sends a runtime message and resolves undefined instead of rejecting when nobody answers. */
export async function sendRuntime<T>(message: unknown): Promise<T | undefined> {
  try {
    return (await ext.runtime.sendMessage(message)) as T;
  } catch {
    return undefined;
  }
}
