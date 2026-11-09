import type { ViewState } from "../../shared/messages";

/**
 * A sidebar view shows one kind of `ViewState` (its `kind`). The sidebar keeps the view while the kind stays
 * the same and passes it each new state and tick.
 */
export interface SidebarView {
  /** Renders into `root`. */
  mount(root: HTMLElement): void;
  update(state: ViewState): void;
  tick?(tick: unknown): void;
  unmount?(): void;
}

export interface ViewEnvironment {
  /** Sends a command to the feature in the page. */
  command(command: string, args?: unknown): void;
}

export type ViewFactory = (environment: ViewEnvironment) => SidebarView;
