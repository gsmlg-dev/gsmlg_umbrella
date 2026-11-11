import assert from "node:assert/strict";
import { afterEach, describe, test } from "node:test";

import ProxyRulesSourceViewer, {
  sourcePageUrl,
} from "./proxy_rules_source_viewer.js";

afterEach(() => {
  delete globalThis.fetch;
});

describe("proxy rule source viewer", () => {
  test("builds bounded page URLs with encoded cursors", () => {
    assert.strictEqual(sourcePageUrl("/proxy-rules/sources/local-direct", "a+b", 200), "/proxy-rules/sources/local-direct?limit=200&cursor=a%2Bb");
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

      assert.strictEqual(viewer.source, "local-direct");
      assert.strictEqual((requests).length, 0);
      assert.strictEqual(root.content.textContent, "");

      root.click(root.viewButton);
      await settle();

      assert.deepStrictEqual(requests, [
        "/proxy-rules/sources/local-direct?limit=200",
      ]);
      assert.strictEqual(root.content.textContent, "direct.example");
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
      assert.strictEqual((requests).length, 0);
      root.click(root.viewButton);
      await settle();

      assert.deepStrictEqual(requests, [
        "/proxy-rules/sources/gfwlist?limit=200",
        "/proxy-rules/sources/gfwlist?limit=200&cursor=next",
      ]);
      assert.strictEqual(root.content.textContent, "one\ntwo\nthree");
      assert.strictEqual(root.loading.textContent, "Loaded all 3 lines.");
      assert.deepStrictEqual(viewer.cache.get("gfwlist"), {
        version: "a".repeat(64),
        totalLines: 3,
        content: "one\ntwo\nthree",
      });
      assert.strictEqual(Object.hasOwn(viewer.cache.get("gfwlist"), "lines"), false);
    });
  });

  test("preserves no newline, one terminal newline, and a trailing blank line", async () => {
    const cases = [
      {
        pages: [page({ version: "a", lines: ["a"], endsWithNewline: false })],
        content: "a",
      },
      {
        pages: [page({ version: "a", lines: ["a"], endsWithNewline: true })],
        content: "a\n",
      },
      {
        pages: [
          page({
            version: "a",
            lines: ["a"],
            nextCursor: "next",
            totalLines: 2,
            endsWithNewline: true,
          }),
          page({
            version: "a",
            startLine: 2,
            lines: [""],
            totalLines: 2,
            endsWithNewline: true,
          }),
        ],
        content: "a\n\n",
      },
    ];

    for (const testCase of cases) {
      await withViewer(async ({ root, viewer }) => {
        let requestCount = 0;
        globalThis.fetch = async () =>
          response(testCase.pages[requestCount++]);

        viewer.mounted();
        root.click(root.viewButton);
        await settle();

        assert.strictEqual(root.content.textContent, testCase.content);
        assert.strictEqual(viewer.cache.get("gfwlist").content, testCase.content);
      });
    }
  });

  test("rejects inconsistent terminal newline metadata across pages", async () => {
    await withViewer(async ({ root, viewer }) => {
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;
        return response(
          requestCount === 1
            ? page({
                version: "a",
                lines: ["a"],
                nextCursor: "next",
                totalLines: 2,
                endsWithNewline: false,
              })
            : page({
                version: "a",
                startLine: 2,
                lines: ["b"],
                totalLines: 2,
                endsWithNewline: true,
              }),
        );
      };

      viewer.mounted();
      root.click(root.viewButton);
      await settle();

      assert.strictEqual(root.error.textContent, "The source returned an invalid response.");
      assert.strictEqual(root.content.textContent, "");
      assert.strictEqual(viewer.cache.has("gfwlist"), false);
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

      assert.strictEqual(root.content.textContent, "");
      root.click(root.viewButton);
      await settle();
      assert.strictEqual(root.content.textContent, "direct.example");

      root.click(root.gfwlistButton);
      assert.strictEqual(root.content.textContent, "");
      root.click(root.directButton);
      assert.strictEqual(root.content.textContent, "direct.example");
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
      assert.strictEqual(viewer.cache.has("local-direct"), false);
      assert.strictEqual(viewer.cache.has("local-proxy"), true);

      root.click(root.proxyButton);
      assert.strictEqual(root.content.textContent, "proxy.example");
    });
  });

  test("updated reloads a selected cached source whose metadata version changed", async () => {
    await withViewer(async ({ root, viewer }) => {
      root.gfwlistButton.dataset.version = "a".repeat(64);
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;
        return response(
          page({
            version: requestCount === 1 ? "a" : "b",
            lines: [requestCount === 1 ? "stale.example" : "fresh.example"],
          }),
        );
      };

      viewer.mounted();
      root.click(root.viewButton);
      await settle();
      assert.strictEqual(root.content.textContent, "stale.example");

      root.gfwlistButton.dataset.version = "b".repeat(64);
      viewer.updated();
      await settle();

      assert.strictEqual(requestCount, 2);
      assert.strictEqual(root.content.textContent, "fresh.example");
      assert.strictEqual(viewer.cache.get("gfwlist").version, "b".repeat(64));
    });
  });

  test("updated invalidates only an inactive cached source with a changed version", async () => {
    await withViewer(async ({ root, viewer }) => {
      root.proxyButton.dataset.version = "b".repeat(64);
      root.directButton.dataset.version = "d".repeat(64);
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

      root.proxyButton.dataset.version = "c".repeat(64);
      viewer.updated();

      assert.strictEqual(viewer.cache.has("local-proxy"), false);
      assert.strictEqual(viewer.cache.has("local-direct"), true);
      assert.strictEqual(root.content.textContent, "direct.example");
    });
  });

  test("never caches an in-flight response after selector metadata changes", async () => {
    await withViewer(async ({ root, viewer }) => {
      root.gfwlistButton.dataset.version = "a".repeat(64);
      const stale = deferred();
      let requestCount = 0;
      globalThis.fetch = () => {
        requestCount += 1;
        return requestCount === 1
          ? stale.promise
          : Promise.resolve(
              response(page({ version: "b", lines: ["fresh.example"] })),
            );
      };

      viewer.mounted();
      root.click(root.viewButton);
      root.gfwlistButton.dataset.version = "b".repeat(64);
      viewer.updated();
      stale.resolve(response(page({ version: "a", lines: ["stale.example"] })));
      await settle();

      assert.strictEqual(requestCount, 2);
      assert.strictEqual(root.content.textContent, "fresh.example");
      assert.strictEqual(viewer.cache.get("gfwlist").version, "b".repeat(64));
      assert.strictEqual((root.content.textContent).includes("stale.example"), false);
    });
  });

  test("updated reloads an active uncached source when metadata advances", async () => {
    await withViewer(async ({ root, viewer }) => {
      root.gfwlistButton.dataset.version = "a".repeat(64);
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;
        return requestCount === 1
          ? response({}, 503)
          : response(page({ version: "b", lines: ["recovered.example"] }));
      };

      viewer.mounted();
      root.click(root.viewButton);
      await settle();
      assert.strictEqual(viewer.cache.has("gfwlist"), false);

      root.gfwlistButton.dataset.version = "b".repeat(64);
      viewer.updated();
      await settle();

      assert.strictEqual(requestCount, 2);
      assert.strictEqual(root.error.textContent, "");
      assert.strictEqual(root.content.textContent, "recovered.example");
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

      assert.strictEqual(root.content.textContent, hostile);
      assert.strictEqual(root.content.innerHTMLWrites, 0);
      assert.strictEqual((root.queries).includes("#proxy-rules-source-spacer"), false);
      assert.strictEqual((root.queries).includes("#proxy-rules-source-rows"), false);
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

      assert.deepStrictEqual(requests, [
        "/proxy-rules/sources/gfwlist?limit=200",
        "/proxy-rules/sources/gfwlist?limit=200&cursor=stale",
        "/proxy-rules/sources/gfwlist?limit=200",
      ]);
      assert.strictEqual(root.content.textContent, "fresh.example");
      assert.strictEqual((root.content.textContent).includes("discarded.example"), false);
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

      assert.strictEqual(requestCount, 4);
      assert.strictEqual(root.loading.textContent, "");
      assert.strictEqual(root.error.textContent, "Source content changed. Try again.");
      assert.ok(root.error.textContent.length <= 160);
      assert.strictEqual(root.content.textContent, "");
      assert.strictEqual(viewer.cache.has("gfwlist"), false);
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

        assert.strictEqual(requestCount, 2);
        assert.strictEqual(root.loading.textContent, "");
        assert.strictEqual(root.error.textContent, testCase.message);
        assert.ok(root.error.textContent.length <= 160);
        assert.strictEqual(root.content.textContent, "");
        assert.strictEqual(viewer.cache.has("gfwlist"), false);
      });
    }
  });

  test("shows and disables loading controls until the complete source resolves", async () => {
    await withViewer(async ({ root, viewer }) => {
      const pending = deferred();
      globalThis.fetch = () => pending.promise;

      viewer.mounted();
      root.click(root.viewButton);

      assert.strictEqual(root.loading.textContent, "Loading source content…");
      assert.strictEqual(root.viewButton.getAttribute("disabled"), "");
      assert.strictEqual(root.viewButton.getAttribute("aria-disabled"), "true");
      assert.strictEqual(root.content.textContent, "");

      pending.resolve(response(page({ version: "a", lines: ["ready.example"] })));
      await settle();

      assert.strictEqual(root.loading.textContent, "Loaded all 1 line.");
      assert.strictEqual(root.viewButton.getAttribute("disabled"), null);
      assert.strictEqual(root.viewButton.getAttribute("aria-disabled"), "false");
      assert.strictEqual(root.content.textContent, "ready.example");
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

        assert.strictEqual(root.loading.textContent, "");
        assert.strictEqual(root.error.textContent, message);
        assert.ok(root.error.textContent.length <= 160);
        assert.strictEqual(root.content.textContent, "");
        assert.strictEqual(root.viewButton.getAttribute("disabled"), null);
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

        assert.strictEqual(root.loading.textContent, "");
        assert.strictEqual(root.error.textContent, testCase.message);
        assert.ok(root.error.textContent.length <= 160);
        assert.strictEqual(root.content.textContent, "");
        assert.strictEqual((root.content.textContent).includes("secret"), false);
        assert.strictEqual(root.viewButton.getAttribute("disabled"), null);
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

      assert.strictEqual(root.gfwlistButton.getAttribute("aria-pressed"), "false");
      assert.strictEqual(root.proxyButton.getAttribute("aria-pressed"), "true");
      assert.strictEqual(root.proxyButton.dataset.loaded, "false");
      assert.strictEqual(root.viewButton.getAttribute("disabled"), "");
      assert.strictEqual(root.viewButton.getAttribute("aria-disabled"), "true");
      assert.strictEqual(root.loading.textContent, "Loading source content…");
      assert.strictEqual(root.error.textContent, "");

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
      assert.strictEqual(root.listeners.has("click"), true);

      viewer.destroyed();
      viewer.destroyed = null;
      await settle();

      assert.strictEqual(aborted, true);
      assert.strictEqual(root.listeners.has("click"), false);
      assert.deepStrictEqual(removedEventRefs, ["source-change-ref"]);
      assert.strictEqual(root.viewButton.getAttribute("disabled"), null);
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
  endsWithNewline = false,
}) {
  return {
    version: version.repeat(64),
    start_line: startLine,
    lines,
    next_cursor: nextCursor,
    has_more: nextCursor !== null,
    total_lines: totalLines,
    ends_with_newline: endsWithNewline,
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
  const button = new FakeElement({
    dataset: { source, loaded: "false", version: "" },
  });
  button.setAttribute("aria-pressed", String(selected));
  return button;
}
