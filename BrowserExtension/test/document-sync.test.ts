import assert from "node:assert/strict";
import { test } from "node:test";
import { DocumentSync } from "../src/content/document-sync";
import type { FeatureContext } from "../src/content/feature";
import type { BridgeRequest, BridgeResponse } from "../src/shared/bridge-types";
import { DEFAULT_SETTINGS } from "../src/shared/settings";

/** A fake app: answers `sync` like Plamonic, translating everything at once. */
function fakeApp(options: { forgetAfter?: number; unreachableFor?: number } = {}) {
  const requests: BridgeRequest[] = [];
  let known = false;
  const context: FeatureContext = {
    async bridge(request) {
      requests.push(request);
      if (options.unreachableFor && requests.length <= options.unreachableFor) {
        return { ok: false, error: "appNotRunning", message: "no socket" } satisfies BridgeResponse;
      }
      if (request.type !== "sync") return { ok: true };
      if (options.forgetAfter && requests.length === options.forgetAfter) known = false;
      if (!request.items && !known) return { ok: false, error: "unknownDocument" };
      if (request.items) known = true;
      const results = (request.want ?? []).map((id) => ({ id, state: "final" as const, text: `訳 ${id}` }));
      return { ok: true, results, progress: { done: 3, total: 3 } };
    },
    injectIntoPage: async () => true,
    settings: () => DEFAULT_SETTINGS,
    viewChanged: () => {},
    tick: () => {},
    hasSidebar: () => false,
    toggleSidebar: () => {},
    finished: () => {},
    site: () => undefined,
    pauseSite: () => {},
  };
  return { context, requests };
}

const items = [
  { id: "a", text: "First line." },
  { id: "b", text: "Second line." },
  { id: "c", text: "Third line." },
];

const until = async (condition: () => boolean, timeout = 3000) => {
  const deadline = Date.now() + timeout;
  while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(condition(), "condition not met in time");
};

test("sends the texts once, collects results and closes the document when stopped", async () => {
  const app = fakeApp();
  let changes = 0;
  const sync = new DocumentSync(app.context, { document: "yt:x", kind: "captions", items, onChange: () => changes++ });
  sync.setFocus("b");
  sync.start();
  await until(() => sync.results.size === 3);
  assert.equal(sync.results.get("b")?.text, "訳 b");
  assert.equal(sync.status.state, "ok");
  assert.ok(changes > 0);
  const first = app.requests[0] as Extract<BridgeRequest, { type: "sync" }>;
  assert.equal(first.items?.length, 3);
  assert.equal(first.focus, "b");
  assert.equal(first.kind, "captions");
  // Moving the focus asks again at once, without the texts.
  sync.setFocus("c");
  await until(() => app.requests.length >= 2);
  assert.equal((app.requests[1] as Extract<BridgeRequest, { type: "sync" }>).items, undefined);
  sync.stop();
  await until(() => app.requests.some((request) => request.type === "close"));
});

test("sends the texts again when the app forgot the document", async () => {
  const app = fakeApp({ forgetAfter: 2 });
  const sync = new DocumentSync(app.context, { document: "yt:x", kind: "captions", items, onChange: () => {} });
  sync.start();
  await until(() => sync.results.size === 3);
  sync.setFocus("c");
  await until(() => app.requests.length >= 3);
  const syncs = app.requests.filter((request) => request.type === "sync") as Extract<BridgeRequest, { type: "sync" }>[];
  assert.ok(syncs[0]!.items);
  assert.equal(syncs[1]!.items, undefined);
  assert.ok(syncs[2]!.items, "texts sent again after unknownDocument");
  sync.stop();
});

test("reports when the app is not running, and recovers on retry", async () => {
  const app = fakeApp({ unreachableFor: 1 });
  const sync = new DocumentSync(app.context, { document: "yt:x", kind: "captions", items, onChange: () => {} });
  sync.start();
  await until(() => sync.status.state === "unreachable");
  sync.retry();
  await until(() => sync.status.state === "ok" && sync.results.size === 3);
  sync.stop();
});

test("a page sends what is on screen, and asks for those results first, then the rest of the page", async () => {
  const app = fakeApp();
  const many = Array.from({ length: 6 }, (_, index) => ({ id: `p${index}`, text: `Paragraph ${index}.` }));
  const sync = new DocumentSync(app.context, { document: "page:x", kind: "page", items: many, onChange: () => {} });
  sync.setVisible(["p4", "p1"]);
  sync.start();
  await until(() => app.requests.length >= 1);
  const first = app.requests[0] as Extract<BridgeRequest, { type: "sync" }>;
  assert.deepEqual(first.visible, ["p4", "p1"]);
  assert.equal(first.focus, "p4");
  // On screen first, then from the focus on, then the part above it.
  assert.deepEqual(first.want, ["p4", "p1", "p2", "p3", "p5", "p0"]);
  sync.stop();
});

test("two tabs on the same page are two documents in the app", async () => {
  const app = fakeApp();
  const one = new DocumentSync(app.context, { document: "page:x", kind: "page", items, onChange: () => {} });
  const two = new DocumentSync(app.context, { document: "page:x", kind: "page", items, onChange: () => {} });
  one.start();
  two.start();
  await until(() => app.requests.length >= 2);
  const ids = new Set(app.requests.map((request) => (request as { document?: string }).document));
  assert.equal(ids.size, 2);
  for (const id of ids) assert.ok(id?.startsWith("page:x#"));
  one.stop();
  two.stop();
});

test("texts changed while a request is out are sent with the next one", async () => {
  const app = fakeApp();
  let release: () => void = () => {};
  const bridge = app.context.bridge;
  // The first request waits until the texts have changed.
  app.context.bridge = async (request) => {
    if (app.requests.length === 0) await new Promise<void>((resolve) => (release = resolve));
    return bridge(request);
  };
  const sync = new DocumentSync(app.context, { document: "page:x", kind: "page", items, onChange: () => {} });
  sync.start();
  await new Promise((resolve) => setTimeout(resolve, 10));
  const grown = [...items, { id: "d", text: "Fourth line." }];
  sync.setItems(grown);
  release();
  await until(() => app.requests.length >= 2);
  const second = app.requests[1] as Extract<BridgeRequest, { type: "sync" }>;
  assert.equal(second.items?.length, 4);
  sync.stop();
});

test("keeps asking for texts that failed, since the app tries them again", async () => {
  const app = fakeApp();
  const bridge = app.context.bridge;
  let calls = 0;
  // The first answer says "b" failed (the app is backing off); later ones have it translated.
  app.context.bridge = async (request) => {
    const response = await bridge(request);
    if (request.type === "sync" && calls++ === 0 && response.ok) {
      response.results = response.results?.map((result) =>
        result.id === "b" ? { id: "b", state: "failed" as const } : result,
      );
    }
    return response;
  };
  const sync = new DocumentSync(app.context, { document: "yt:x", kind: "captions", items, onChange: () => {} });
  sync.start();
  await until(() => sync.results.get("b")?.state === "failed");
  sync.retry();
  await until(() => sync.results.get("b")?.state === "final");
  const second = app.requests[1] as Extract<BridgeRequest, { type: "sync" }>;
  assert.ok(second.want?.includes("b"));
  sync.stop();
});
