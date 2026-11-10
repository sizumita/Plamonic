import type { Feature } from "../content/feature";
import { pageTranslation } from "./page";
import { postButtons } from "./posts";
import { youtubeCaptions } from "./youtube";

/**
 * Every feature. Auto features start on the pages they match (their sites must also be in CONTENT_MATCHES in
 * scripts/build.mjs); manual ones are offered in the toolbar menu. The first one with a sidebar view owns the
 * sidebar.
 */
export const FEATURES: Feature[] = [youtubeCaptions, postButtons, pageTranslation];
