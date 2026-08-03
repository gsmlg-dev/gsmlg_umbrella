import { describe, expect, test } from "bun:test";

import ProxyRulesSourceViewer, {
  appendPage,
  cachedLine,
  descriptorForLine,
  physicalLayout,
  rebaseScroll,
  restorePage,
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

    expect([cachedLine(first, 0), cachedLine(first, 1)]).toEqual([
      "one",
      "two",
    ]);
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

    expect(empty).toMatchObject({
      version: "a".repeat(64),
      nextCursor: null,
      hasMore: false,
      totalLines: 0,
    });
    expect(cachedLine(reset, 0)).toBe("fresh");
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

    expect(cachedLine(first, 0)).toBe("one");
    expect(first.hasMore).toBe(true);
    expect([cachedLine(second, 0), cachedLine(second, 1)]).toEqual([
      "one",
      "two",
    ]);
    expect(second.hasMore).toBe(false);
    expect(second).not.toBe(first);
    expect(second.pages).not.toBe(first.pages);
    expect(second.pages[0]).toBe(first.pages[0]);
    expect(firstPage.lines).toEqual(["one"]);
  });

  test("keeps a fixed page and line cache while appending cursor descriptors", () => {
    let state = null;

    for (let pageIndex = 0; pageIndex < 20; pageIndex += 1) {
      const startLine = pageIndex * 100 + 1;
      const hasMore = pageIndex < 19;
      state = appendPage(
        state,
        {
          version: "a".repeat(64),
          start_line: startLine,
          lines: Array.from(
            { length: 100 },
            (_value, index) => `line-${startLine + index}`,
          ),
          next_cursor: hasMore ? `cursor-${pageIndex + 1}` : null,
          has_more: hasMore,
          total_lines: 2_000,
        },
        {
          cursor: pageIndex === 0 ? null : `cursor-${pageIndex}`,
          maxCachedLines: 300,
          maxCachedPages: 3,
        },
      );
    }

    expect(state.pages).toHaveLength(3);
    expect(
      state.pages.reduce((count, page) => count + page.lines.length, 0),
    ).toBe(300);
    expect(state.loadedThrough).toBe(2_000);
    expect(cachedLine(state, 0)).toBeUndefined();
    expect(cachedLine(state, 1_999)).toBe("line-2000");
    expect(descriptorForLine(state, 50).startLine).toBe(1);
    expect(descriptorForLine(state, 1_950).startLine).toBe(1_901);
  });

  test("keeps million-line physical height bounded and rebases to the final line", () => {
    const totalLines = 4_000_000;
    const rowHeight = 24;
    const maxPhysicalHeight = 8_000_000;
    let segmentStartLine = 0;
    let iterations = 0;

    while (iterations < 40) {
      const layout = physicalLayout({
        totalLines,
        rowHeight,
        segmentStartLine,
        maxPhysicalHeight,
      });
      expect(layout.height).toBeLessThanOrEqual(maxPhysicalHeight);
      if (segmentStartLine === layout.maxStartLine) break;

      const scrollTop = Math.floor(layout.height * 0.8);
      const logicalLine = segmentStartLine + Math.floor(scrollTop / rowHeight);
      const rebased = rebaseScroll({
        segmentStartLine,
        scrollTop,
        viewportHeight: 384,
        totalLines,
        rowHeight,
        maxPhysicalHeight,
      });

      expect(
        rebased.segmentStartLine + Math.floor(rebased.scrollTop / rowHeight),
      ).toBe(logicalLine);
      expect(rebased.segmentStartLine).toBeGreaterThan(segmentStartLine);
      segmentStartLine = rebased.segmentStartLine;
      iterations += 1;
    }

    const finalLayout = physicalLayout({
      totalLines,
      rowHeight,
      segmentStartLine,
      maxPhysicalHeight,
    });
    const finalScrollTop = (totalLines - segmentStartLine - 1) * rowHeight;

    expect(segmentStartLine).toBe(finalLayout.maxStartLine);
    expect(finalScrollTop).toBeLessThan(maxPhysicalHeight);
    expect(segmentStartLine + Math.floor(finalScrollTop / rowHeight)).toBe(
      totalLines - 1,
    );

    const backwardScrollTop = Math.floor(finalLayout.height * 0.1);
    const backwardLogicalLine =
      segmentStartLine + Math.floor(backwardScrollTop / rowHeight);
    const backward = rebaseScroll({
      segmentStartLine,
      scrollTop: backwardScrollTop,
      viewportHeight: 384,
      totalLines,
      rowHeight,
      maxPhysicalHeight,
    });

    expect(backward.segmentStartLine).toBeLessThan(segmentStartLine);
    expect(
      backward.segmentStartLine + Math.floor(backward.scrollTop / rowHeight),
    ).toBe(backwardLogicalLine);
  });

  test("restores an evicted page by its cursor without changing the tail", () => {
    let state = null;

    for (let pageIndex = 0; pageIndex < 5; pageIndex += 1) {
      state = appendPage(state, sourcePage(pageIndex, 5, 100), {
        cursor: pageIndex === 0 ? null : `cursor-${pageIndex}`,
        maxCachedLines: 200,
        maxCachedPages: 2,
      });
    }

    const tailDescriptor = state.lastDescriptor;
    expect(cachedLine(state, 0)).toBeUndefined();

    const restored = restorePage(state, sourcePage(0, 5, 100), {
      cursor: null,
      maxCachedLines: 200,
      maxCachedPages: 2,
    });

    expect(cachedLine(restored, 0)).toBe("line-1");
    expect(restored.pages).toHaveLength(2);
    expect(restored.loadedThrough).toBe(500);
    expect(restored.lastDescriptor).toBe(tailDescriptor);
  });

  test("appends 100k, 200k, and 400k lines with bounded near-linear work", () => {
    const results = [100_000, 200_000, 400_000].map((lineCount) =>
      buildLargeState(lineCount),
    );

    for (const result of results) {
      expect(result.state.loadedThrough).toBe(result.lineCount);
      expect(cachedLineCount(result.state)).toBeLessThanOrEqual(2_000);
      expect(result.state.pages.length).toBeLessThanOrEqual(12);
      expect(result.linkedDescriptors).toBe(result.pageCount - 1);
    }

    expect(results[2].duration).toBeLessThan(results[0].duration * 8 + 100);
    expect(results[2].duration).toBeLessThan(results[1].duration * 4 + 100);
  });
});

describe("ProxyRulesSourceViewer hook", () => {
  test("catches up far forward with zero descriptor scans and linear page fetches", async () => {
    const results = [];
    for (const pageCount of [50, 100, 200]) {
      results.push(await runFarForwardCatchUp(pageCount));
    }

    for (const result of results) {
      expect(result.fetchCount).toBe(result.pageCount);
      expect(result.loadedThrough).toBe(result.pageCount * result.pageSize);
      expect(result.descriptorVisits).toBe(0);
    }

    expect(results[2].duration).toBeLessThan(results[0].duration * 8 + 100);
    expect(results[2].duration).toBeLessThan(results[1].duration * 4 + 100);
  });

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

  test("caps the physical spacer for a multi-million-line source", async () => {
    await withFakeDom(async ({ root, viewer }) => {
      globalThis.fetch = async () =>
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 1,
          lines: Array.from(
            { length: 200 },
            (_value, index) => `line-${index + 1}`,
          ),
          next_cursor: "cursor-1",
          has_more: true,
          total_lines: 4_000_000,
        });

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();

      expect(Number.parseInt(root.spacer.style.height, 10)).toBeLessThanOrEqual(
        8_000_000,
      );
      viewer.destroyed();
    });
  });

  test("refetches an evicted page when navigating backward", async () => {
    await withFakeDom(async ({ root, viewer, frames }) => {
      const requests = [];
      globalThis.fetch = async (url) => {
        requests.push(url);
        const cursor = new URL(url, "https://example.test").searchParams.get(
          "cursor",
        );
        const pageIndex = cursor ? Number(cursor.slice("cursor-".length)) : 0;
        return jsonResponse(200, sourcePage(pageIndex, 13, 200));
      };

      viewer.mounted();
      viewer.activated = true;
      for (let pageIndex = 0; pageIndex < 13; pageIndex += 1) {
        root.viewport.scrollTop = Math.max(0, pageIndex * 200 - 4) * 24;
        await viewer.loadNextPage();
      }

      expect(requests).toHaveLength(13);
      expect(cachedLine(viewer.state, 0)).toBeUndefined();
      expect(viewer.state.loadedThrough).toBe(2_600);

      root.viewport.scrollTop = 0;
      root.viewport.listeners.get("scroll")();
      const [[frameId, renderFrame]] = frames;
      frames.delete(frameId);
      renderFrame();
      await flushPromises();

      expect(requests).toHaveLength(14);
      expect(requests[13]).toBe("/proxy-rules/sources/gfwlist?limit=200");
      expect(cachedLine(viewer.state, 0)).toBe("line-1");
      expect(viewer.state.loadedThrough).toBe(2_600);
      viewer.destroyed();
    });
  });

  test("rebases forward to the final logical rows with bounded fetches", async () => {
    await withFakeDom(async ({ root, viewer, frames }) => {
      let requestCount = 0;
      globalThis.fetch = async (_url, options) => {
        requestCount += 1;
        if (requestCount === 1) {
          return jsonResponse(200, {
            version: "a".repeat(64),
            start_line: 1,
            lines: Array.from(
              { length: 200 },
              (_value, index) => `line-${index + 1}`,
            ),
            next_cursor: "cursor-1",
            has_more: true,
            total_lines: 4_000_000,
          });
        }

        return new Promise((_resolve, reject) => {
          options.signal.addEventListener("abort", () => {
            const error = new Error("aborted");
            error.name = "AbortError";
            reject(error);
          });
        });
      };

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();

      for (let iteration = 0; iteration < 40; iteration += 1) {
        const layout = viewer.physicalLayout();
        if (viewer.segmentStartLine === layout.maxStartLine) break;
        root.viewport.scrollTop = Math.floor(layout.height * 0.8);
        root.viewport.listeners.get("scroll")();
        const [[frameId, renderFrame]] = frames;
        frames.delete(frameId);
        renderFrame();
      }

      const finalLayout = viewer.physicalLayout();
      root.viewport.scrollTop = finalLayout.height - root.viewport.clientHeight;
      viewer.renderWindow();
      const finalRow = root.rows.children.at(-1);

      expect(viewer.segmentStartLine).toBe(finalLayout.maxStartLine);
      expect(finalRow.children[0].textContent).toBe("4000000");
      expect(requestCount).toBe(2);
      viewer.destroyed();
      await flushPromises();
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
      expect(cachedLine(viewer.state, 0)).toBe("fresh");

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
      expect(viewer.state.loadedThrough).toBe(21);
      viewer.destroyed();
    });
  });

  test("blocks a failed later page until an explicit View retry", async () => {
    await withFakeDom(async ({ root, viewer, frames }) => {
      const firstLines = Array.from(
        { length: 20 },
        (_value, index) => `line-${index + 1}`,
      );
      const requests = [];
      globalThis.fetch = async () => {
        requests.push(requests.length + 1);

        if (requests.length === 1) {
          return jsonResponse(200, {
            version: "a".repeat(64),
            start_line: 1,
            lines: firstLines,
            next_cursor: "next",
            has_more: true,
            total_lines: 21,
          });
        }

        if (requests.length === 2) return jsonResponse(404, null);

        return jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 21,
          lines: ["line-21"],
          next_cursor: null,
          has_more: false,
          total_lines: 21,
        });
      };

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();
      root.viewport.scrollTop = 10 * 24;
      root.viewport.listeners.get("scroll")();

      const [[frameId, renderFrame]] = frames;
      frames.delete(frameId);
      renderFrame();
      await flushPromises();

      expect(requests).toHaveLength(2);
      root.viewport.listeners.get("scroll")();
      const [[blockedFrameId, blockedFrame]] = frames;
      frames.delete(blockedFrameId);
      blockedFrame();
      await flushPromises();
      expect(requests).toHaveLength(2);

      root.click(root.viewButton);
      await flushPromises();
      expect(requests).toHaveLength(3);
      expect(viewer.state.loadedThrough).toBe(21);
      viewer.destroyed();
    });
  });

  test("blocks a second page conflict instead of starting another reload loop", async () => {
    await withFakeDom(async ({ root, viewer, frames }) => {
      const firstLines = Array.from(
        { length: 20 },
        (_value, index) => `line-${index + 1}`,
      );
      let requestCount = 0;
      globalThis.fetch = async () => {
        requestCount += 1;

        if (requestCount === 2 || requestCount === 4) {
          return jsonResponse(409, null);
        }

        if (requestCount === 5) {
          return jsonResponse(200, {
            version: "a".repeat(64),
            start_line: 21,
            lines: ["line-21"],
            next_cursor: null,
            has_more: false,
            total_lines: 21,
          });
        }

        return jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 1,
          lines: firstLines,
          next_cursor: "next",
          has_more: true,
          total_lines: 21,
        });
      };

      viewer.mounted();
      viewer.activated = true;
      await viewer.loadNextPage();

      await scrollNearEnd(root, frames);
      expect(requestCount).toBe(3);
      await scrollNearEnd(root, frames);
      expect(requestCount).toBe(4);
      await scrollNearEnd(root, frames);
      expect(requestCount).toBe(4);

      root.click(root.viewButton);
      await flushPromises();
      expect(requestCount).toBe(5);
      expect(viewer.state.loadedThrough).toBe(21);
      viewer.destroyed();
    });
  });

  test("keeps later-page 422 and 503 failures blocked across scrolling", async () => {
    for (const status of [422, 503]) {
      await withFakeDom(async ({ root, viewer, frames }) => {
        const firstLines = Array.from(
          { length: 20 },
          (_value, index) => `line-${index + 1}`,
        );
        let requestCount = 0;
        globalThis.fetch = async () => {
          requestCount += 1;
          if (requestCount > 1) return jsonResponse(status, null);

          return jsonResponse(200, {
            version: "a".repeat(64),
            start_line: 1,
            lines: firstLines,
            next_cursor: "next",
            has_more: true,
            total_lines: 21,
          });
        };

        viewer.mounted();
        viewer.activated = true;
        await viewer.loadNextPage();
        await scrollNearEnd(root, frames);
        await scrollNearEnd(root, frames);

        expect(requestCount).toBe(2);
        viewer.destroyed();
      });
    }
  });

  test("blocks later-page network and invalid response failures", async () => {
    const invalidPages = [
      () => Promise.reject(new Error("network")),
      () => ({
        ok: true,
        status: 200,
        json: async () => Promise.reject(new Error("invalid json")),
      }),
      () => jsonResponse(200, { invalid: "schema" }),
      () =>
        jsonResponse(200, {
          version: "b".repeat(64),
          start_line: 21,
          lines: ["line-21"],
          next_cursor: null,
          has_more: false,
          total_lines: 21,
        }),
      () =>
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 22,
          lines: ["line-21"],
          next_cursor: null,
          has_more: false,
          total_lines: 21,
        }),
    ];

    for (const failedResponse of invalidPages) {
      await withFakeDom(async ({ root, viewer, frames }) => {
        const firstLines = Array.from(
          { length: 20 },
          (_value, index) => `line-${index + 1}`,
        );
        let requestCount = 0;
        globalThis.fetch = async () => {
          requestCount += 1;
          if (requestCount > 1) return failedResponse();

          return jsonResponse(200, {
            version: "a".repeat(64),
            start_line: 1,
            lines: firstLines,
            next_cursor: "next",
            has_more: true,
            total_lines: 21,
          });
        };

        viewer.mounted();
        viewer.activated = true;
        await viewer.loadNextPage();
        await scrollNearEnd(root, frames);
        await scrollNearEnd(root, frames);

        expect(requestCount).toBe(2);
        expect(viewer.state.loadedThrough).toBe(20);
        viewer.destroyed();
      });
    }
  });

  test("rehydrates patched controls and messages without resetting loaded rows", async () => {
    await withFakeDom(async ({ root, viewer }) => {
      globalThis.fetch = async () =>
        jsonResponse(200, {
          version: "a".repeat(64),
          start_line: 1,
          lines: ["local.example"],
          next_cursor: null,
          has_more: false,
          total_lines: 1,
        });

      viewer.mounted();
      viewer.switchSource("local-proxy");
      viewer.activated = true;
      await viewer.loadNextPage();
      viewer.setError("Client-side message.");
      const state = viewer.state;
      const rows = root.rows.children;

      root.gfwlistButton.setAttribute("aria-pressed", "true");
      root.gfwlistButton.dataset.loaded = "true";
      root.localButton.setAttribute("aria-pressed", "false");
      root.localButton.dataset.loaded = "false";
      root.status.textContent = "server patch";
      root.error.textContent = "server patch";

      viewer.updated();

      expect(root.gfwlistButton.getAttribute("aria-pressed")).toBe("false");
      expect(root.gfwlistButton.dataset.loaded).toBe("false");
      expect(root.localButton.getAttribute("aria-pressed")).toBe("true");
      expect(root.localButton.dataset.loaded).toBe("true");
      expect(root.status.textContent).toBe("Loaded 1 of 1 lines.");
      expect(root.error.textContent).toBe("Client-side message.");
      expect(viewer.source).toBe("local-proxy");
      expect(viewer.state).toBe(state);
      expect(root.rows.children).toBe(rows);
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
    return await callback({ root, viewer, frames });
  } finally {
    globalThis.document = originals.document;
    globalThis.fetch = originals.fetch;
    globalThis.requestAnimationFrame = originals.requestAnimationFrame;
    globalThis.cancelAnimationFrame = originals.cancelAnimationFrame;
  }
}

async function runFarForwardCatchUp(pageCount) {
  return withFakeDom(async ({ root, viewer, frames }) => {
    const pageSize = 20;
    let descriptorVisits = 0;
    let fetchCount = 0;
    globalThis.fetch = async (url) => {
      fetchCount += 1;
      const cursor = new URL(url, "https://example.test").searchParams.get(
        "cursor",
      );
      const pageIndex = cursor ? Number(cursor.slice("cursor-".length)) : 0;
      return jsonResponse(200, sourcePage(pageIndex, pageCount, pageSize));
    };

    viewer.mounted();
    viewer.onDescriptorVisit = () => {
      descriptorVisits += 1;
    };
    viewer.activated = true;
    await viewer.loadNextPage();

    root.viewport.scrollTop = (pageCount * pageSize - 4) * 24;
    root.viewport.listeners.get("scroll")();
    const [[frameId, renderFrame]] = frames;
    frames.delete(frameId);
    const startedAt = performance.now();
    renderFrame();

    for (
      let iteration = 0;
      iteration < pageCount * 20 &&
      viewer.state.loadedThrough < pageCount * pageSize;
      iteration += 1
    ) {
      await Promise.resolve();
    }

    const result = {
      descriptorVisits,
      duration: performance.now() - startedAt,
      fetchCount,
      loadedThrough: viewer.state.loadedThrough,
      pageCount,
      pageSize,
    };
    viewer.destroyed();
    return result;
  });
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

async function scrollNearEnd(root, frames) {
  root.viewport.scrollTop = 10 * 24;
  root.viewport.listeners.get("scroll")();
  const [[frameId, renderFrame]] = frames;
  frames.delete(frameId);
  renderFrame();
  await flushPromises();
}

function sourcePage(pageIndex, pageCount, pageSize) {
  const startLine = pageIndex * pageSize + 1;
  const hasMore = pageIndex < pageCount - 1;
  return {
    version: "a".repeat(64),
    start_line: startLine,
    lines: Array.from(
      { length: pageSize },
      (_value, index) => `line-${startLine + index}`,
    ),
    next_cursor: hasMore ? `cursor-${pageIndex + 1}` : null,
    has_more: hasMore,
    total_lines: pageCount * pageSize,
  };
}

function buildLargeState(lineCount) {
  const pageSize = 500;
  const pageCount = lineCount / pageSize;
  const lines = Array.from({ length: pageSize }, () => "x");
  let state = null;
  let linkedDescriptors = 0;
  const startedAt = performance.now();

  for (let pageIndex = 0; pageIndex < pageCount; pageIndex += 1) {
    const previousDescriptor = state?.lastDescriptor || null;
    const hasMore = pageIndex < pageCount - 1;
    state = appendPage(
      state,
      {
        version: "a".repeat(64),
        start_line: pageIndex * pageSize + 1,
        lines,
        next_cursor: hasMore ? `cursor-${pageIndex + 1}` : null,
        has_more: hasMore,
        total_lines: lineCount,
      },
      { cursor: pageIndex === 0 ? null : `cursor-${pageIndex}` },
    );
    if (
      state.lastDescriptor.previous === previousDescriptor &&
      previousDescriptor
    ) {
      linkedDescriptors += 1;
    }
  }

  return {
    duration: performance.now() - startedAt,
    lineCount,
    linkedDescriptors,
    pageCount,
    state,
  };
}

function cachedLineCount(state) {
  return state.pages.reduce((count, page) => count + page.lines.length, 0);
}
