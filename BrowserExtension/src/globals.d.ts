/** Set by scripts/build.mjs. */
declare const __BROWSER__: "chrome" | "safari";
/** Chrome's native messaging host name (Safari ignores it and talks to the extension's own app). */
declare const __NATIVE_HOST__: string;
declare const __VERSION__: string;

/** CSS files are bundled as text (scripts/build.mjs). */
declare module "*.css" {
  const text: string;
  export default text;
}
