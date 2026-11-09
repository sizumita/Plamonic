import { BROWSER, ext } from "../shared/api";
import type { BridgeRequest, BridgeResponse, BridgeStatus } from "../shared/bridge-types";

/**
 * Talks to the Plamonic app through native messaging. Safari delivers the message to the extension's own app
 * (its .appex); Chrome starts the native host named `__NATIVE_HOST__`. Both forward it to the app's socket.
 */
export class NativeBridge {
  private status: BridgeStatus = { state: "unknown" };
  private statusCheckedAt = 0;

  async call(request: BridgeRequest): Promise<BridgeResponse> {
    let response: BridgeResponse;
    try {
      const raw = await ext.runtime.sendNativeMessage(__NATIVE_HOST__, { ...request, client: BROWSER });
      response = normalize(raw);
    } catch (error) {
      response = { ok: false, error: "unreachable", message: String((error as Error)?.message ?? error) };
    }
    if (response.error === "unreachable" || response.error === "appNotRunning") {
      this.setStatus({ state: "unreachable", message: response.message ?? "" });
    } else if (request.type === "hello" && response.ok) {
      this.setStatus({
        state: "connected",
        version: response.version ?? "",
        enabled: response.enabled ?? false,
        ready: response.ready ?? false,
        targetLanguage: response.targetLanguage ?? "",
        features: response.features ?? [],
      });
    } else if (response.error === "disabled" && this.status.state === "connected") {
      this.setStatus({ ...this.status, enabled: false });
    }
    return response;
  }

  /** The last known status; asks the app again when it is older than `maxAge` milliseconds. */
  async currentStatus(maxAge = 5000): Promise<BridgeStatus> {
    if (Date.now() - this.statusCheckedAt > maxAge) await this.call({ type: "hello" });
    return this.status;
  }

  private setStatus(status: BridgeStatus) {
    this.status = status;
    this.statusCheckedAt = Date.now();
  }
}

/**
 * Anything that is not a BridgeResponse means the native side could not reach the app: Safari's extension and
 * Chrome's host answer `{error, …}` without `ok` when the socket is missing.
 */
function normalize(raw: unknown): BridgeResponse {
  if (raw && typeof raw === "object" && typeof (raw as BridgeResponse).ok === "boolean") return raw as BridgeResponse;
  const message = raw && typeof raw === "object" ? String((raw as { error?: unknown }).error ?? "") : "";
  return { ok: false, error: "appNotRunning", message };
}
