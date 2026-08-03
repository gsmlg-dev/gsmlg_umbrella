import { describe, expect, test } from "bun:test";

import ProxyRulesSourceViewer, {
  appendPage,
  sourcePageUrl,
  visibleRange,
} from "./proxy_rules_source_viewer.js";

describe("proxy rule source viewer state", () => {
  test("computes a bounded visible window with overscan", () => {
    expect(
      visibleRange({
        scrollTop: 240,
        viewportHeight: 120,
        rowHeight: 24,
        loadedCount: 100,
        overscan: 3,
      }),
    ).toEqual({ start: 7, end: 18 });
  });

  test("clamps visible windows to the loaded line count", () => {
    expect(
      visibleRange({
        scrollTop: 100_000,
        viewportHeight: 120,
        rowHeight: 24,
        loadedCount: 100,
        overscan: 3,
      }),
    ).toEqual({ start: 97, end: 100 });

    expect(
      visibleRange({
        scrollTop: 0,
        viewportHeight: 120,
        rowHeight: 24,
        loadedCount: 0,
      }),
    ).toEqual({ start: 0, end: 0 });
  });

  test("appends one version and rejects mixed versions", () => {
    const first = appendPage(null, {
      version: "a".repeat(64),
      start_line: 1,
      lines: ["one", "two"],
      next_cursor: "cursor",
      has_more: true,
      total_lines: 3,
    });

    expect(first.lines).toEqual(["one", "two"]);
    expect(() =>
      appendPage(first, {
        version: "b".repeat(64),
        start_line: 3,
        lines: ["three"],
        next_cursor: null,
        has_more: false,
        total_lines: 3,
      }),
    ).toThrow("source_changed");
  });

  test("builds encoded cursor URLs", () => {
    expect(sourcePageUrl("/proxy-rules/sources/gfwlist", "a+b", 200)).toBe(
      "/proxy-rules/sources/gfwlist?limit=200&cursor=a%2Bb",
    );
  });

  test("rejects pages that do not continue at the next one-based line", () => {
    const first = appendPage(null, {
      version: "a".repeat(64),
      start_line: 1,
      lines: ["one"],
      next_cursor: "cursor",
      has_more: true,
      total_lines: 3,
    });

    expect(() =>
      appendPage(first, {
        version: "a".repeat(64),
        start_line: 3,
        lines: ["three"],
        next_cursor: null,
        has_more: false,
        total_lines: 3,
      }),
    ).toThrow("non_contiguous_page");
  });

  test("rejects malformed page schemas", () => {
    expect(() =>
      appendPage(null, {
        version: "not-a-version",
        start_line: 1,
        lines: ["one"],
        next_cursor: null,
        has_more: "false",
        total_lines: 1,
      }),
    ).toThrow("invalid_page");
  });

  test("accepts an empty source and resets by starting from null", () => {
    const empty = appendPage(null, {
      version: "a".repeat(64),
      start_line: 1,
      lines: [],
      next_cursor: null,
      has_more: false,
      total_lines: 0,
    });
    const reset = appendPage(null, {
      version: "b".repeat(64),
      start_line: 1,
      lines: ["fresh"],
      next_cursor: null,
      has_more: false,
      total_lines: 1,
    });

    expect(empty).toEqual({
      version: "a".repeat(64),
      lines: [],
      nextCursor: null,
      hasMore: false,
      totalLines: 0,
    });
    expect(reset.lines).toEqual(["fresh"]);
  });

  test("immutably appends pages and preserves has_more", () => {
    const firstPage = {
      version: "a".repeat(64),
      start_line: 1,
      lines: ["one"],
      next_cursor: "next",
      has_more: true,
      total_lines: 2,
    };
    const first = appendPage(null, firstPage);
    const second = appendPage(first, {
      version: "a".repeat(64),
      start_line: 2,
      lines: ["two"],
      next_cursor: null,
      has_more: false,
      total_lines: 2,
    });

    expect(first.lines).toEqual(["one"]);
    expect(first.hasMore).toBe(true);
    expect(second.lines).toEqual(["one", "two"]);
    expect(second.hasMore).toBe(false);
    expect(second).not.toBe(first);
    expect(second.lines).not.toBe(first.lines);
    expect(firstPage.lines).toEqual(["one"]);
  });
});

describe("ProxyRulesSourceViewer hook", () => {
  test("stays lazy across source switches and keeps one abortable same-origin request", async () => {
    await withFakeDom(async ({ root, viewer }) => {
      const requests = [];
      globalThis.fetch = (url, options) => {
        requests.push({ url, options });
        return new Promise((_resolve, reject) => {
          options.signal.addEventListener("abort", () => {
            const error = new Error("aborted");
            error.name = "AbortError";
            reject(error);
          });
        });
      };

      viewer.mounted();
      expect(requests).toHaveLength(0);

      root.click(root.localButton);
      expect(viewer.source).toBe("local-proxy");
      expect(requests).toHaveLength(0);

      root.click(root.viewButton);
      viewer.loadNextPage();
      expect(requests).toHaveLength(1);
      expect(requests[0].url).toBe(
        "/proxy-rules/sources/local-proxy?limit=200",
      );
      expect(requests[0].options.credentials).toBe("same-origin");
      expect(requests[0].options.headers).toEqual({
        Accept: "application/json",
      });
      expect(requests[0].options.signal.aborted).toBe(false);

      root.click(root.gfwlistButton);
      expect(requests[0].options.signal.aborted).toBe(true);
      expect(requests).toHaveLength(1);

      viewer.destroyed();
      expect(root.listenerCount("click")).toBe(0);
      expect(root.viewport.listenerCount("scroll")).toBe(0);
      await Promise.resolve();
    });
  });

  test("renders source text, line numbers, and a total-height spacer safely", async () => {
    await withFakeDom(async ({ root, viewer }) => {
      const sourceText = '<img src=x onerror="alert(1)">';
      globalThis.fetch = async () =>
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 1,
          lines: [sourceText, "second"],
          next_cursor: null,
          has_more: false,
          total_lines: 2,
        });

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();

      expect(root.spacer.style.height).toBe("48px");
      expect(root.rows.children).toHaveLength(2);
      expect(root.rows.children[0].children[0].textContent).toBe("1");
      expect(root.rows.children[0].children[1].textContent).toBe(sourceText);
      expect(root.rows.children[0].innerHTMLWrites).toBe(0);
      expect(root.status.textContent).toBe("Loaded 2 of 2 lines.");

      viewer.destroyed();
    });
  });

  test("reloads once after a 409 and on a matching viewed-source change", async () => {
    await withFakeDom(async ({ root, viewer }) => {
      const responses = [
        jsonResponse(409, null),
        jsonResponse(200, {
          version: "b".repeat(64),
          start_line: 1,
          lines: ["fresh"],
          next_cursor: null,
          has_more: false,
          total_lines: 1,
        }),
      ];
      const requests = [];
      globalThis.fetch = async (url, options) => {
        requests.push({ url, options });
        return responses.shift();
      };

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();

      expect(requests).toHaveLength(2);
      expect(viewer.state.lines).toEqual(["fresh"]);

      let resolveReload;
      globalThis.fetch = (url, options) => {
        requests.push({ url, options });
        return new Promise((resolve) => {
          resolveReload = resolve;
        });
      };
      root.sourceChanged({ source: "local-proxy" });
      expect(requests).toHaveLength(2);
      root.sourceChanged({ source: "gfwlist" });
      expect(requests).toHaveLength(3);

      resolveReload(
        jsonResponse(200, {
          version: "c".repeat(64),
          start_line: 1,
          lines: [],
          next_cursor: null,
          has_more: false,
          total_lines: 0,
        }),
      );
      await flushPromises();
      viewer.destroyed();
    });
  });

  test("coalesces scroll rendering and requests the next page near the loaded end", async () => {
    await withFakeDom(async ({ root, viewer, frames }) => {
      const firstLines = Array.from(
        { length: 20 },
        (_value, index) => `line-${index + 1}`,
      );
      const responses = [
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 1,
          lines: firstLines,
          next_cursor: "next",
          has_more: true,
          total_lines: 21,
        }),
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 21,
          lines: ["line-21"],
          next_cursor: null,
          has_more: false,
          total_lines: 21,
        }),
      ];
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;
        return responses.shift();
      };

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();
      expect(requestCount).toBe(1);

      root.viewport.scrollTop = 10 * 24;
      root.viewport.listeners.get("scroll")();
      root.viewport.listeners.get("scroll")();
      expect(frames.size).toBe(1);

      const [[frameId, renderFrame]] = frames;
      frames.delete(frameId);
      renderFrame();
      await flushPromises();

      expect(requestCount).toBe(2);
      expect(viewer.state.lines).toHaveLength(21);
      viewer.destroyed();
    });
  });

  test("uses bounded messages for server, network, and invalid JSON failures", async () => {
    const cases = [
      [async () => jsonResponse(404, null), "Source content was not found."],
      [
        async () => jsonResponse(409, null),
        "Source content changed. Try again.",
      ],
      [
        async () => jsonResponse(422, null),
        "The source page could not be loaded.",
      ],
      [
        async () => jsonResponse(503, null),
        "Source content is temporarily unavailable.",
      ],
      [
        async () => Promise.reject(new Error("/private/secret")),
        "Source content could not be loaded.",
      ],
      [
        async () => ({
          ok: true,
          status: 200,
          json: async () => Promise.reject(new Error("bad")),
        }),
        "The source returned an invalid response.",
      ],
    ];

    for (const [fetchResponse, expectedMessage] of cases) {
      await withFakeDom(async ({ root, viewer }) => {
        globalThis.fetch = fetchResponse;
        viewer.mounted();
        viewer.activated = true;
        await viewer.loadNextPage();

        expect(root.error.textContent).toBe(expectedMessage);
        expect(root.error.textContent).not.toContain("/private/");
        expect(root.error.textContent.length).toBeLessThan(80);
        viewer.destroyed();
      });
    }
  });
});

async function withFakeDom(callback) {
  const originals = {
    document: globalThis.document,
    fetch: globalThis.fetch,
    requestAnimationFrame: globalThis.requestAnimationFrame,
    cancelAnimationFrame: globalThis.cancelAnimationFrame,
  };
  const root = new FakeRoot();
  const frames = new Map();
  let nextFrame = 1;

  globalThis.document = {
    createElement: () => new FakeElement(),
    createDocumentFragment: () => new FakeFragment(),
  };
  globalThis.requestAnimationFrame = (callback) => {
    const id = nextFrame;
    nextFrame += 1;
    frames.set(id, callback);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => frames.delete(id);

  const viewer = {
    ...ProxyRulesSourceViewer,
    el: root,
    handleEvent(_name, handler) {
      root.sourceChanged = handler;
      return 17;
    },
    removeHandleEvent(reference) {
      root.removedHandleEvent = reference;
    },
  };

  try {
    await callback({ root, viewer, frames });
  } finally {
    globalThis.document = originals.document;
    globalThis.fetch = originals.fetch;
    globalThis.requestAnimationFrame = originals.requestAnimationFrame;
    globalThis.cancelAnimationFrame = originals.cancelAnimationFrame;
  }
}

class FakeElement {
  constructor({ id = null, dataset = {} } = {}) {
    this.id = id;
    this.dataset = { ...dataset };
    this.attributes = new Map();
    this.children = [];
    this.listeners = new Map();
    this.style = {};
    this.textContent = "";
    this.className = "";
    this.scrollTop = 0;
    this.clientHeight = 96;
    this.innerHTMLWrites = 0;
  }

  addEventListener(name, listener) {
    this.listeners.set(name, listener);
  }

  removeEventListener(name, listener) {
    if (this.listeners.get(name) === listener) this.listeners.delete(name);
  }

  listenerCount(name) {
    return this.listeners.has(name) ? 1 : 0;
  }

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }

  getAttribute(name) {
    return this.attributes.get(name);
  }

  closest(selector) {
    if (selector === "[data-source]" && this.dataset.source) return this;
    if (
      selector === "#proxy-rules-view-content" &&
      this.id === selector.slice(1)
    ) {
      return this;
    }
    return null;
  }

  append(...children) {
    this.children.push(...children);
  }

  appendChild(child) {
    this.children.push(child);
  }

  replaceChildren(...children) {
    this.children = children.flatMap((child) =>
      child instanceof FakeFragment ? child.children : [child],
    );
  }
}

class FakeFragment extends FakeElement {}

class FakeRoot extends FakeElement {
  constructor() {
    super({
      id: "proxy-rules-source-viewer",
      dataset: {
        pageSize: "200",
        gfwlistUrl: "/proxy-rules/sources/gfwlist",
        localProxyUrl: "/proxy-rules/sources/local-proxy",
      },
    });
    this.gfwlistButton = new FakeElement({ dataset: { source: "gfwlist" } });
    this.gfwlistButton.setAttribute("aria-pressed", "true");
    this.localButton = new FakeElement({ dataset: { source: "local-proxy" } });
    this.localButton.setAttribute("aria-pressed", "false");
    this.viewButton = new FakeElement({ id: "proxy-rules-view-content" });
    this.viewport = new FakeElement({ id: "proxy-rules-source-viewport" });
    this.spacer = new FakeElement({ id: "proxy-rules-source-spacer" });
    this.rows = new FakeElement({ id: "proxy-rules-source-rows" });
    this.status = new FakeElement({ id: "proxy-rules-viewer-loading" });
    this.error = new FakeElement({ id: "proxy-rules-viewer-error" });
    this.elements = [
      this.gfwlistButton,
      this.localButton,
      this.viewButton,
      this.viewport,
      this.spacer,
      this.rows,
      this.status,
      this.error,
    ];
  }

  querySelector(selector) {
    if (selector === '[data-source][aria-pressed="true"]') {
      return [this.gfwlistButton, this.localButton].find(
        (button) => button.getAttribute("aria-pressed") === "true",
      );
    }

    return (
      this.elements.find((element) => `#${element.id}` === selector) || null
    );
  }

  querySelectorAll(selector) {
    return selector === "[data-source]"
      ? [this.gfwlistButton, this.localButton]
      : [];
  }

  contains(element) {
    return this.elements.includes(element);
  }

  click(target) {
    this.listeners.get("click")?.({ target });
  }
}

function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}
