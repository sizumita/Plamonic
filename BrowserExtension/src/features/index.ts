import type { Feature } from "../content/feature";
import { youtubeCaptions } from "./youtube";

/**
 * Every feature, in priority order: the content script runs the first one that matches the page.
 * Each feature's sites must also be in CONTENT_MATCHES in scripts/build.mjs.
 */
export const FEATURES: Feature[] = [youtubeCaptions];
