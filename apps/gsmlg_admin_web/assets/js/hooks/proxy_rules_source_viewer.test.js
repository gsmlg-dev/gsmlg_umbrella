import { afterEach, describe, expect, test } from "bun:test";

import ProxyRulesSourceViewer, {
  sourcePageUrl,
} from "./proxy_rules_source_viewer.js";

afterEach(() => {
  delete globalThis.fetch;
});

describe("proxy rule source viewer", () => {
  test("builds bounded page URLs with encoded cursors", () => {
    expect(sourcePageUrl("/proxy-rules/sources/local-direct", "a+b", 200)).toBe(
      "/proxy-rules/sources/local-direct?limit=200&cursor=a%2Bb",
    );
  });

  test("selects Local Direct lazily and routes it to its own URL", async () => {
    await withViewer(async ({ root, viewer }) => {
      const requests = [];
      globalThis.fetch = async (url) => {
        requests.push(url);
        return response(page({ version: "d", lines: ["direct.example"] }));
      };

      viewer.mounted();
      root.click(root.directButton);

      expect(viewer.source).toBe("local-direct");
      expect(requests).toHaveLength(0);
      expect(root.content.textContent).toBe("");

      root.click(root.viewButton);
      await settle();

      expect(requests).toEqual([
        "/proxy-rules/sources/local-direct?limit=200",
      ]);
      expect(root.content.textContent).toBe("direct.example");
    });
  });

  test("loads every bounded page and renders the complete source", async () => {
    await withViewer(async ({ root, viewer }) => {
      const requests = [];
      globalThis.fetch = async (url) => {
        requests.push(url);
        return url.includes("cursor=next")
          ? response(
              page({
                version: "a",
                startLine: 3,
                lines: ["three"],
                totalLines: 3,
              }),
            )
          : response(
              page({
                version: "a",
                lines: ["one", "two"],
                nextCursor: "next",
                totalLines: 3,
              }),
            );
      };

      viewer.mounted();
      expect(requests).toHaveLength(0);
      root.click(root.viewButton);
      await settle();

      expect(requests).toEqual([
        "/proxy-rules/sources/gfwlist?limit=200",
        "/proxy-rules/sources/gfwlist?limit=200&cursor=next",
      ]);
      expect(root.content.textContent).toBe("one\ntwo\nthree");
      expect(root.loading.textContent).toBe("Loaded all 3 lines.");
      expect(viewer.cache.get("gfwlist")).toEqual({
        version: "a".repeat(64),
        totalLines: 3,
        content: "one\ntwo\nthree",
      });
      expect(Object.hasOwn(viewer.cache.get("gfwlist"), "lines")).toBe(false);
    });
  });

  test("ignores stale responses when switching and restores complete cached text", async () => {
    await withViewer(async ({ root, viewer }) => {
      const remote = deferred();
      globalThis.fetch = (url) => {
        if (url.includes("gfwlist")) return remote.promise;
        return Promise.resolve(
          response(page({ version: "d", lines: ["direct.example"] })),
        );
      };

      viewer.mounted();
      root.click(root.viewButton);
      root.click(root.directButton);
      remote.resolve(response(page({ version: "a", lines: ["stale.example"] })));
      await settle();

      expect(root.content.textContent).toBe("");
      root.click(root.viewButton);
      await settle();
      expect(root.content.textContent).toBe("direct.example");

      root.click(root.gfwlistButton);
      expect(root.content.textContent).toBe("");
      root.click(root.directButton);
      expect(root.content.textContent).toBe("direct.example");
    });
  });

  test("invalidates only the named source including Local Direct", async () => {
    await withViewer(async ({ root, viewer, sourceChanged }) => {
      globalThis.fetch = async (url) =>
        response(
          url.includes("local-direct")
            ? page({ version: "d", lines: ["direct.example"] })
            : page({ version: "b", lines: ["proxy.example"] }),
        );

      viewer.mounted();
      root.click(root.proxyButton);
      root.click(root.viewButton);
      await settle();
      root.click(root.directButton);
      root.click(root.viewButton);
      await settle();

      sourceChanged.callback({ source: "local-direct" });
      expect(viewer.cache.has("local-direct")).toBe(false);
      expect(viewer.cache.has("local-proxy")).toBe(true);

      root.click(root.proxyButton);
      expect(root.content.textContent).toBe("proxy.example");
    });
  });

  test("renders hostile source text only through textContent without virtual rows", async () => {
    await withViewer(async ({ root, viewer }) => {
      const hostile = '<img src=x onerror="globalThis.pwned=true">';
      globalThis.fetch = async () =>
        response(page({ version: "a", lines: [hostile] }));

      viewer.mounted();
      root.click(root.viewButton);
      await settle();

      expect(root.content.textContent).toBe(hostile);
      expect(root.content.innerHTMLWrites).toBe(0);
      expect(root.queries).not.toContain("#proxy-rules-source-spacer");
      expect(root.queries).not.toContain("#proxy-rules-source-rows");
    });
  });

  test("discards a successful first page and restarts once after a later-page 409", async () => {
    await withViewer(async ({ root, viewer }) => {
      const requests = [];
      globalThis.fetch = async (url) => {
        requests.push(url);
        if (requests.length === 1) {
          return response(
            page({
              version: "a",
              lines: ["discarded.example"],
              nextCursor: "stale",
              totalLines: 2,
            }),
          );
        }
        if (requests.length === 2) return response({}, 409);
        return response(page({ version: "b", lines: ["fresh.example"] }));
      };

      viewer.mounted();
      root.click(root.viewButton);
      await settle();

      expect(requests).toEqual([
        "/proxy-rules/sources/gfwlist?limit=200",
        "/proxy-rules/sources/gfwlist?limit=200&cursor=stale",
        "/proxy-rules/sources/gfwlist?limit=200",
      ]);
      expect(root.content.textContent).toBe("fresh.example");
      expect(root.content.textContent).not.toContain("discarded.example");
    });
  });

  test("stops after a second later-page 409 without exposing partial content", async () => {
    await withViewer(async ({ root, viewer }) => {
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;
        if (requestCount === 2 || requestCount === 4) return response({}, 409);
        return response(
          page({
            version: requestCount === 1 ? "a" : "b",
            lines: [`partial-${requestCount}.example`],
            nextCursor: "next",
            totalLines: 2,
          }),
        );
      };

      viewer.mounted();
      root.click(root.viewButton);
      await settle();

      expect(requestCount).toBe(4);
      expect(root.loading.textContent).toBe("");
      expect(root.error.textContent).toBe("Source content changed. Try again.");
      expect(root.error.textContent.length).toBeLessThanOrEqual(160);
      expect(root.content.textContent).toBe("");
      expect(viewer.cache.has("gfwlist")).toBe(false);
    });
  });

  test("later-page failures never expose or cache partial content", async () => {
    const cases = [
      {
        later: async () => response({}, 503),
        message: "Source content is temporarily unavailable.",
      },
      {
        later: async () => {
          throw new Error("later-network-secret");
        },
        message: "Source content could not be loaded.",
      },
      {
        later: async () =>
          response(page({ version: "a", startLine: 99, lines: ["bad"] })),
        message: "The source returned an invalid response.",
      },
    ];

    for (const testCase of cases) {
      await withViewer(async ({ root, viewer }) => {
        let requestCount = 0;
        globalThis.fetch = async () => {
          requestCount += 1;
          if (requestCount > 1) return testCase.later();
          return response(
            page({
              version: "a",
              lines: ["partial-secret.example"],
              nextCursor: "next",
              totalLines: 2,
            }),
          );
        };

        viewer.mounted();
        root.click(root.viewButton);
        await settle();

        expect(requestCount).toBe(2);
        expect(root.loading.textContent).toBe("");
        expect(root.error.textContent).toBe(testCase.message);
        expect(root.error.textContent.length).toBeLessThanOrEqual(160);
        expect(root.content.textContent).toBe("");
        expect(viewer.cache.has("gfwlist")).toBe(false);
      });
    }
  });

  test("shows and disables loading controls until the complete source resolves", async () => {
    await withViewer(async ({ root, viewer }) => {
      const pending = deferred();
      globalThis.fetch = () => pending.promise;

      viewer.mounted();
      root.click(root.viewButton);

      expect(root.loading.textContent).toBe("Loading source content…");
      expect(root.viewButton.getAttribute("disabled")).toBe("");
      expect(root.viewButton.getAttribute("aria-disabled")).toBe("true");
      expect(root.content.textContent).toBe("");

      pending.resolve(response(page({ version: "a", lines: ["ready.example"] })));
      await settle();

      expect(root.loading.textContent).toBe("Loaded all 1 line.");
      expect(root.viewButton.getAttribute("disabled")).toBeNull();
      expect(root.viewButton.getAttribute("aria-disabled")).toBe("false");
      expect(root.content.textContent).toBe("ready.example");
    });
  });

  test("shows bounded terminal server errors and clears loading", async () => {
    for (const [status, message] of [
      [404, "Source content was not found."],
      [422, "The source page could not be loaded."],
      [503, "Source content is temporarily unavailable."],
    ]) {
      await withViewer(async ({ root, viewer }) => {
        globalThis.fetch = async () => response({}, status);

        viewer.mounted();
        root.click(root.viewButton);
        await settle();

        expect(root.loading.textContent).toBe("");
        expect(root.error.textContent).toBe(message);
        expect(root.error.textContent.length).toBeLessThanOrEqual(160);
        expect(root.content.textContent).toBe("");
        expect(root.viewButton.getAttribute("disabled")).toBeNull();
      });
    }
  });

  test("shows bounded errors without stale content for network and invalid responses", async () => {
    const cases = [
      {
        fetch: async () => {
          throw new Error("network-secret-" + "x".repeat(500));
        },
        message: "Source content could not be loaded.",
      },
      {
        fetch: async () => ({
          ok: true,
          status: 200,
          async json() {
            throw new Error("invalid-json-secret");
          },
        }),
        message: "The source returned an invalid response.",
      },
      {
        fetch: async () => response({ lines: ["payload-secret.example"] }),
        message: "The source returned an invalid response.",
      },
    ];

    for (const testCase of cases) {
      await withViewer(async ({ root, viewer }) => {
        globalThis.fetch = testCase.fetch;

        viewer.mounted();
        root.click(root.viewButton);
        await settle();

        expect(root.loading.textContent).toBe("");
        expect(root.error.textContent).toBe(testCase.message);
        expect(root.error.textContent.length).toBeLessThanOrEqual(160);
        expect(root.content.textContent).toBe("");
        expect(root.content.textContent).not.toContain("secret");
        expect(root.viewButton.getAttribute("disabled")).toBeNull();
      });
    }
  });

  test("updated rehydrates selected, loaded, loading, and message state", async () => {
    await withViewer(async ({ root, viewer }) => {
      const pending = deferred();
      globalThis.fetch = () => pending.promise;

      viewer.mounted();
      root.click(root.proxyButton);
      root.click(root.viewButton);

      root.gfwlistButton.setAttribute("aria-pressed", "true");
      root.proxyButton.setAttribute("aria-pressed", "false");
      root.proxyButton.dataset.loaded = "true";
      root.viewButton.removeAttribute("disabled");
      root.viewButton.setAttribute("aria-disabled", "false");
      root.loading.textContent = "patched away";
      root.error.textContent = "patched away";

      viewer.updated();

      expect(root.gfwlistButton.getAttribute("aria-pressed")).toBe("false");
      expect(root.proxyButton.getAttribute("aria-pressed")).toBe("true");
      expect(root.proxyButton.dataset.loaded).toBe("false");
      expect(root.viewButton.getAttribute("disabled")).toBe("");
      expect(root.viewButton.getAttribute("aria-disabled")).toBe("true");
      expect(root.loading.textContent).toBe("Loading source content…");
      expect(root.error.textContent).toBe("");

      pending.resolve(response(page({ version: "b", lines: ["proxy.example"] })));
      await settle();
    });
  });

  test("destroyed aborts the active request and removes hook listeners", async () => {
    await withViewer(async ({ root, viewer, removedEventRefs }) => {
      let aborted = false;
      globalThis.fetch = (_url, { signal }) =>
        new Promise((_resolve, reject) => {
          signal.addEventListener("abort", () => {
            aborted = true;
            const error = new Error("aborted");
            error.name = "AbortError";
            reject(error);
          });
        });

      viewer.mounted();
      root.click(root.viewButton);
      expect(root.listeners.has("click")).toBe(true);

      viewer.destroyed();
      viewer.destroyed = null;
      await settle();

      expect(aborted).toBe(true);
      expect(root.listeners.has("click")).toBe(false);
      expect(removedEventRefs).toEqual(["source-change-ref"]);
      expect(root.viewButton.getAttribute("disabled")).toBeNull();
    });
  });
});

async function withViewer(callback) {
  const priorDocument = globalThis.document;
  const root = new FakeRoot();
  const sourceChanged = {};
  const removedEventRefs = [];
  const viewer = {
    ...ProxyRulesSourceViewer,
    el: root,
    handleEvent(_name, callback) {
      sourceChanged.callback = callback;
      return "source-change-ref";
    },
    removeHandleEvent(ref) {
      removedEventRefs.push(ref);
    },
  };

  globalThis.document = {};

  try {
    await callback({ root, viewer, sourceChanged, removedEventRefs });
  } finally {
    viewer.destroyed?.();
    globalThis.document = priorDocument;
  }
}

async function settle() {
  for (let index = 0; index < 10; index += 1) {
    await Promise.resolve();
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

function page({
  version,
  startLine = 1,
  lines,
  nextCursor = null,
  totalLines = lines.length,
}) {
  return {
    version: version.repeat(64),
    start_line: startLine,
    lines,
    next_cursor: nextCursor,
    has_more: nextCursor !== null,
    total_lines: totalLines,
  };
}

function response(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    },
  };
}

function deferred() {
  let resolve;
  const promise = new Promise((resolver) => {
    resolve = resolver;
  });
  return { promise, resolve };
}

class FakeElement {
  constructor({ id = null, dataset = {} } = {}) {
    this.id = id;
    this.dataset = { ...dataset };
    this.attributes = new Map();
    this.listeners = new Map();
    this._textContent = "";
    this.innerHTMLWrites = 0;
  }

  set textContent(value) {
    this._textContent = String(value);
  }

  get textContent() {
    return this._textContent;
  }

  set innerHTML(_value) {
    this.innerHTMLWrites += 1;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  addEventListener(name, callback) {
    this.listeners.set(name, callback);
  }

  removeEventListener(name) {
    this.listeners.delete(name);
  }

  closest(selector) {
    if (selector === "[data-source]" && this.dataset.source) return this;
    if (selector === "#proxy-rules-view-content" && this.id === selector.slice(1)) return this;
    return null;
  }
}

class FakeRoot extends FakeElement {
  constructor() {
    super({ id: "proxy-rules-source-viewer" });
    this.dataset.pageSize = "200";
    this.dataset.gfwlistUrl = "/proxy-rules/sources/gfwlist";
    this.dataset.localProxyUrl = "/proxy-rules/sources/local-proxy";
    this.dataset.localDirectUrl = "/proxy-rules/sources/local-direct";
    this.gfwlistButton = sourceButton("gfwlist", true);
    this.proxyButton = sourceButton("local-proxy", false);
    this.directButton = sourceButton("local-direct", false);
    this.viewButton = new FakeElement({ id: "proxy-rules-view-content" });
    this.content = new FakeElement({ id: "proxy-rules-source-content" });
    this.loading = new FakeElement({ id: "proxy-rules-viewer-loading" });
    this.error = new FakeElement({ id: "proxy-rules-viewer-error" });
    this.queries = [];
  }

  contains(element) {
    return element !== null;
  }

  click(target) {
    this.listeners.get("click")?.({ target });
  }

  querySelector(selector) {
    this.queries.push(selector);
    if (selector === '[data-source][aria-pressed="true"]') {
      return this.sourceButtons().find(
        (button) => button.getAttribute("aria-pressed") === "true",
      );
    }
    return {
      "#proxy-rules-view-content": this.viewButton,
      "#proxy-rules-source-content": this.content,
      "#proxy-rules-viewer-loading": this.loading,
      "#proxy-rules-viewer-error": this.error,
    }[selector] ?? null;
  }

  querySelectorAll(selector) {
    return selector === "[data-source]" ? this.sourceButtons() : [];
  }

  sourceButtons() {
    return [this.gfwlistButton, this.proxyButton, this.directButton];
  }
}

function sourceButton(source, selected) {
  const button = new FakeElement({ dataset: { source, loaded: "false" } });
  button.setAttribute("aria-pressed", String(selected));
  return button;
}
