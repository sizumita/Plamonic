import { CAPTIONS_VIEW } from "../../features/youtube/view";
import { CaptionsView } from "./captions-view";
import { StatusView } from "./status-view";
import type { ViewFactory } from "./view";

/** Sidebar views by `ViewState.kind`. A feature with its own sidebar adds its view here. */
export const VIEWS: Record<string, ViewFactory> = {
  [CAPTIONS_VIEW]: (environment) => new CaptionsView(environment),
};

/** For kinds without a view: pages without a feature, or that the extension cannot run on. */
export const fallbackView: ViewFactory = () => new StatusView();
