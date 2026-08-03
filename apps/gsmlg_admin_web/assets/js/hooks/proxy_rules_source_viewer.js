export function visibleRange({
  scrollTop,
  viewportHeight,
  rowHeight,
  loadedCount,
  overscan = 5,
}) {
  const count = Math.max(0, Math.floor(loadedCount));
  const height = rowHeight > 0 ? rowHeight : 1;
  const first = Math.min(count, Math.floor(Math.max(0, scrollTop) / height));
  const visible = Math.ceil(Math.max(0, viewportHeight) / height);
  const extra = Math.max(0, Math.floor(overscan));

  return {
    start: Math.max(0, first - extra),
    end: Math.min(count, first + visible + extra),
  };
}

export function sourcePageUrl(base, cursor, limit) {
  const params = new URLSearchParams({ limit: String(limit) });
  if (cursor) params.set("cursor", cursor);
  return `${base}?${params.toString()}`;
}

const DEFAULT_MAX_CACHED_LINES = 2_000;
const DEFAULT_MAX_CACHED_PAGES = 12;
export const MAX_PHYSICAL_HEIGHT = 8_000_000;

export function appendPage(state, page, options = {}) {
  if (!validPage(page)) throw new Error("invalid_page");
  if (state && state.version !== page.version)
    throw new Error("source_changed");

  const expectedStart = (state?.loadedThrough || 0) + 1;
  if (page.start_line !== expectedStart) throw new Error("non_contiguous_page");

  const loadedCount = expectedStart - 1 + page.lines.length;
  const totalMatches = !state || state.totalLines === page.total_lines;
  const cursorMatches = page.has_more
    ? typeof page.next_cursor === "string" &&
      page.next_cursor.length > 0 &&
      page.lines.length > 0 &&
      loadedCount < page.total_lines
    : page.next_cursor === null && loadedCount === page.total_lines;

  if (!totalMatches || loadedCount > page.total_lines || !cursorMatches) {
    throw new Error("invalid_page");
  }

  const cursor = Object.hasOwn(options, "cursor")
    ? options.cursor
    : state?.nextCursor || null;
  if (cursor !== null && typeof cursor !== "string")
    throw new Error("invalid_page");
  if (state && cursor !== state.nextCursor) throw new Error("invalid_page");

  const descriptor = Object.freeze({
    cursor,
    startLine: page.start_line,
    lineCount: page.lines.length,
    nextCursor: page.next_cursor,
    hasMore: page.has_more,
    previous: state?.lastDescriptor || null,
  });
  const cache = addCachedPage(state?.pages || [], page, options);

  return {
    version: page.version,
    pages: cache.pages,
    loadedThrough: loadedCount,
    lastDescriptor: descriptor,
    nextCursor: page.next_cursor,
    hasMore: page.has_more,
    totalLines: page.total_lines,
  };
}

export function cachedLine(state, lineIndex) {
  if (!state || !Number.isSafeInteger(lineIndex) || lineIndex < 0)
    return undefined;

  for (const page of state.pages) {
    const offset = lineIndex - (page.startLine - 1);
    if (offset >= 0 && offset < page.lines.length) return page.lines[offset];
  }

  return undefined;
}

export function descriptorForLine(state, lineIndex) {
  if (!state || !Number.isSafeInteger(lineIndex) || lineIndex < 0) return null;

  let descriptor = state.lastDescriptor;
  while (descriptor) {
    const startIndex = descriptor.startLine - 1;
    if (
      lineIndex >= startIndex &&
      lineIndex < startIndex + descriptor.lineCount
    ) {
      return descriptor;
    }
    descriptor = descriptor.previous;
  }

  return null;
}

export function restorePage(state, page, options = {}) {
  if (!state || !validPage(page)) throw new Error("invalid_page");
  if (state.version !== page.version) throw new Error("source_changed");
  if (state.totalLines !== page.total_lines) throw new Error("invalid_page");

  const cursor = Object.hasOwn(options, "cursor") ? options.cursor : null;
  if (cursor !== null && typeof cursor !== "string")
    throw new Error("invalid_page");
  const descriptor = descriptorForLine(state, page.start_line - 1);
  if (
    !descriptor ||
    descriptor.cursor !== cursor ||
    descriptor.startLine !== page.start_line ||
    descriptor.lineCount !== page.lines.length ||
    descriptor.nextCursor !== page.next_cursor ||
    descriptor.hasMore !== page.has_more
  ) {
    throw new Error("non_contiguous_page");
  }

  const cache = addCachedPage(state.pages, page, options);
  return {
    ...state,
    pages: cache.pages,
  };
}

export function physicalLayout({
  totalLines,
  rowHeight,
  segmentStartLine = 0,
  maxPhysicalHeight = MAX_PHYSICAL_HEIGHT,
}) {
  const safeRowHeight = positiveInteger(rowHeight, 1);
  const safeTotal = nonNegativeInteger(totalLines);
  const capacity = Math.max(
    1,
    Math.floor(
      positiveInteger(maxPhysicalHeight, MAX_PHYSICAL_HEIGHT) / safeRowHeight,
    ),
  );
  const maxStartLine = Math.max(0, safeTotal - capacity);
  const startLine = Math.min(
    maxStartLine,
    Math.max(0, nonNegativeInteger(segmentStartLine)),
  );
  const lineCount = Math.min(capacity, safeTotal - startLine);

  return {
    capacity,
    startLine,
    lineCount,
    height: lineCount * safeRowHeight,
    maxStartLine,
  };
}

export function rebaseScroll({
  segmentStartLine,
  scrollTop,
  viewportHeight,
  totalLines,
  rowHeight,
  maxPhysicalHeight = MAX_PHYSICAL_HEIGHT,
}) {
  const layout = physicalLayout({
    totalLines,
    rowHeight,
    segmentStartLine,
    maxPhysicalHeight,
  });
  const safeRowHeight = positiveInteger(rowHeight, 1);
  const safeViewportHeight = Math.max(0, viewportHeight);
  const maxScrollTop = Math.max(0, layout.height - safeViewportHeight);
  const safeScrollTop = Math.min(maxScrollTop, Math.max(0, scrollTop));
  const halfSegment = Math.max(1, Math.floor(layout.capacity / 2));
  let nextStartLine = layout.startLine;
  let nextScrollTop = safeScrollTop;

  if (
    safeScrollTop >= maxScrollTop * 0.75 &&
    layout.startLine < layout.maxStartLine
  ) {
    const shift = Math.min(
      halfSegment,
      Math.floor(safeScrollTop / safeRowHeight),
      layout.maxStartLine - layout.startLine,
    );
    nextStartLine += shift;
    nextScrollTop -= shift * safeRowHeight;
  } else if (safeScrollTop <= maxScrollTop * 0.25 && layout.startLine > 0) {
    const shift = Math.min(halfSegment, layout.startLine);
    nextStartLine -= shift;
    nextScrollTop += shift * safeRowHeight;
  }

  return {
    segmentStartLine: nextStartLine,
    scrollTop: nextScrollTop,
  };
}

function addCachedPage(pages, page, options) {
  const maxCachedLines = positiveInteger(
    options.maxCachedLines,
    DEFAULT_MAX_CACHED_LINES,
  );
  const maxCachedPages = positiveInteger(
    options.maxCachedPages,
    DEFAULT_MAX_CACHED_PAGES,
  );
  const cachedPage = Object.freeze({
    startLine: page.start_line,
    lines: Object.freeze([...page.lines]),
  });
  const nextPages = pages.filter(
    (existingPage) => existingPage.startLine !== cachedPage.startLine,
  );
  nextPages.push(cachedPage);
  let cachedLines = nextPages.reduce(
    (count, existingPage) => count + existingPage.lines.length,
    0,
  );

  while (
    nextPages.length > 1 &&
    (nextPages.length > maxCachedPages || cachedLines > maxCachedLines)
  ) {
    cachedLines -= nextPages.shift().lines.length;
  }

  return { pages: Object.freeze(nextPages) };
}

function positiveInteger(value, fallback) {
  return Number.isSafeInteger(value) && value > 0 ? value : fallback;
}

function nonNegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function validPage(page) {
  return (
    page !== null &&
    typeof page === "object" &&
    /^[0-9a-f]{64}$/.test(page.version) &&
    Number.isSafeInteger(page.start_line) &&
    page.start_line >= 1 &&
    Array.isArray(page.lines) &&
    page.lines.every((line) => typeof line === "string") &&
    Number.isSafeInteger(page.total_lines) &&
    page.total_lines >= 0 &&
    typeof page.has_more === "boolean" &&
    (page.next_cursor === null || typeof page.next_cursor === "string")
  );
}

const ERROR_MESSAGES = {
  404: "Source content was not found.",
  409: "Source content changed. Try again.",
  422: "The source page could not be loaded.",
  503: "Source content is temporarily unavailable.",
};

const ProxyRulesSourceViewer = {
  mounted() {
    this.rowHeight = 24;
    this.overscan = 8;
    this.maxPhysicalHeight = MAX_PHYSICAL_HEIGHT;
    this.segmentStartLine = 0;
    this.pageSize = boundedPageSize(this.el.dataset.pageSize);
    this.state = null;
    this.source = this.selectedSource();
    this.activated = false;
    this.loading = false;
    this.loadBlocked = false;
    this.conflictRetryUsed = false;
    this.requestSerial = 0;
    this.animationFrame = null;
    this.abortController = null;
    this.statusMessage = "";
    this.errorMessage = "";

    this.onScroll = () => {
      if (this.animationFrame !== null) return;

      this.animationFrame = requestAnimationFrame(() => {
        this.animationFrame = null;
        this.rebaseViewport();
        this.renderWindow();
        this.loadVisiblePage();
      });
    };

    this.onClick = (event) => {
      const sourceButton = event.target.closest?.("[data-source]");
      if (sourceButton && this.el.contains(sourceButton)) {
        this.switchSource(sourceButton.dataset.source);
        return;
      }

      const viewButton = event.target.closest?.("#proxy-rules-view-content");
      if (viewButton && this.el.contains(viewButton)) {
        this.activated = true;
        this.loadBlocked = false;
        this.conflictRetryUsed = false;
        this.loadVisiblePage();
      }
    };

    this.viewport().addEventListener("scroll", this.onScroll, {
      passive: true,
    });
    this.el.addEventListener("click", this.onClick);
    this.sourceChangedRef = this.handleEvent(
      "proxy-rules:source-changed",
      ({ source }) => {
        if (source !== this.source) return;

        const reload = this.activated;
        this.resetView({ preserveActivation: reload });
        if (reload) this.loadVisiblePage();
      },
    );

    this.updateSourceButtons();
    this.clearRenderedContent();
  },

  updated() {
    this.updateSourceButtons();
    this.renderMessages();
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.viewport().removeEventListener("scroll", this.onScroll);

    if (this.animationFrame !== null) cancelAnimationFrame(this.animationFrame);
    if (this.abortController) this.abortController.abort();
    if (this.sourceChangedRef !== undefined) {
      this.removeHandleEvent?.(this.sourceChangedRef);
    }

    this.animationFrame = null;
    this.abortController = null;
    this.requestSerial += 1;
  },

  selectedSource() {
    const selected = this.el.querySelector('[data-source][aria-pressed="true"]')
      ?.dataset.source;

    return validSource(selected) ? selected : "gfwlist";
  },

  switchSource(source) {
    if (!validSource(source) || source === this.source) return;

    this.resetView();
    this.source = source;
    this.updateSourceButtons();
  },

  updateSourceButtons() {
    this.el.querySelectorAll("[data-source]").forEach((button) => {
      const selected = button.dataset.source === this.source;
      button.setAttribute("aria-pressed", String(selected));
      button.dataset.loaded = String(selected && this.state !== null);
    });
  },

  resetView({
    preserveActivation = false,
    preserveConflictRetry = false,
  } = {}) {
    this.requestSerial += 1;
    if (this.abortController) this.abortController.abort();

    this.abortController = null;
    this.loading = false;
    this.loadBlocked = false;
    if (!preserveConflictRetry) this.conflictRetryUsed = false;
    this.state = null;
    this.segmentStartLine = 0;
    this.activated = preserveActivation;
    this.clearRenderedContent();
    this.updateSourceButtons();
  },

  clearRenderedContent() {
    this.viewport().scrollTop = 0;
    this.spacer().style.height = "0px";
    this.rows().style.transform = "translateY(0px)";
    this.rows().replaceChildren();
    this.setStatus("");
    this.setError("");
  },

  async loadNextPage({ descriptor = null } = {}) {
    const restoring = descriptor !== null;
    if (
      !this.activated ||
      this.loading ||
      this.loadBlocked ||
      (!restoring && this.state && !this.state.hasMore)
    )
      return;

    const source = this.source;
    const serial = this.requestSerial;
    const cursor = restoring
      ? descriptor.cursor
      : this.state?.nextCursor || null;
    const controller = new AbortController();
    this.abortController = controller;
    this.loading = true;
    this.setError("");
    this.setStatus("Loading source content…");
    let pageAppended = false;

    try {
      const response = await fetch(
        sourcePageUrl(this.sourceUrl(source), cursor, this.pageSize),
        {
          credentials: "same-origin",
          headers: { Accept: "application/json" },
          signal: controller.signal,
        },
      );

      if (serial !== this.requestSerial || source !== this.source) return;

      if (response.status === 409 && !this.conflictRetryUsed) {
        this.conflictRetryUsed = true;
        this.loading = false;
        this.abortController = null;
        this.resetView({
          preserveActivation: true,
          preserveConflictRetry: true,
        });
        this.setStatus("Source content changed. Reloading…");
        return this.loadNextPage();
      }

      if (!response.ok) {
        this.loadBlocked = true;
        this.setStatus("");
        this.setError(
          ERROR_MESSAGES[response.status] ||
            "Source content could not be loaded.",
        );
        return;
      }

      let page;
      try {
        page = await response.json();
      } catch (_error) {
        throw new Error("invalid_response");
      }

      if (serial !== this.requestSerial || source !== this.source) return;

      try {
        this.state = restoring
          ? restorePage(this.state, page, { cursor })
          : appendPage(this.state, page, { cursor });
        pageAppended = true;
      } catch (_error) {
        throw new Error("invalid_response");
      }

      this.markCurrentSourceLoaded();
      this.renderWindow();
      this.setStatus(
        `Loaded ${this.state.loadedThrough} of ${this.state.totalLines} lines.`,
      );
    } catch (error) {
      if (error?.name === "AbortError") return;
      if (serial !== this.requestSerial || source !== this.source) return;

      this.loadBlocked = true;
      this.setStatus("");
      this.setError(
        error?.message === "invalid_response"
          ? "The source returned an invalid response."
          : "Source content could not be loaded.",
      );
    } finally {
      if (this.abortController === controller) {
        this.abortController = null;
        this.loading = false;

        if (pageAppended) {
          queueMicrotask(() => this.loadVisiblePage());
        }
      }
    }
  },

  loadVisiblePage() {
    if (!this.activated || this.loading || this.loadBlocked) return;
    if (this.state === null) {
      this.loadNextPage();
      return;
    }

    const range = this.logicalVisibleRange();
    for (let lineIndex = range.start; lineIndex < range.end; lineIndex += 1) {
      if (cachedLine(this.state, lineIndex) !== undefined) continue;

      const descriptor = descriptorForLine(this.state, lineIndex);
      if (descriptor) {
        this.loadNextPage({ descriptor });
      } else if (this.state.hasMore) {
        this.loadNextPage();
      }
      return;
    }

    if (this.state.hasMore && this.nearLoadedEnd()) {
      this.loadNextPage();
    }
  },

  sourceUrl(source) {
    return source === "local-proxy"
      ? this.el.dataset.localProxyUrl
      : this.el.dataset.gfwlistUrl;
  },

  renderWindow() {
    if (this.state === null) return;

    const layout = this.physicalLayout();
    const range = this.logicalVisibleRange();
    const fragment = document.createDocumentFragment();

    for (let index = range.start; index < range.end; index += 1) {
      const row = document.createElement("div");
      const lineNumber = document.createElement("span");
      const sourceText = document.createElement("span");

      row.className = "flex min-w-max items-start";
      row.style.height = `${this.rowHeight}px`;
      lineNumber.className =
        "w-16 shrink-0 select-none pr-3 text-right text-on-surface-variant";
      lineNumber.textContent = String(index + 1);
      sourceText.className = "whitespace-pre pr-4";
      sourceText.textContent = cachedLine(this.state, index) ?? "";
      row.append(lineNumber, sourceText);
      fragment.appendChild(row);
    }

    this.spacer().style.height = `${layout.height}px`;
    this.rows().style.transform = `translateY(${
      (range.start - layout.startLine) * this.rowHeight
    }px)`;
    this.rows().replaceChildren(fragment);
  },

  physicalLayout() {
    const layout = physicalLayout({
      totalLines: this.state?.totalLines || 0,
      rowHeight: this.rowHeight,
      segmentStartLine: this.segmentStartLine,
      maxPhysicalHeight: this.maxPhysicalHeight,
    });
    this.segmentStartLine = layout.startLine;
    return layout;
  },

  logicalVisibleRange() {
    const viewport = this.viewport();
    const layout = this.physicalLayout();
    const range = visibleRange({
      scrollTop: viewport.scrollTop,
      viewportHeight: viewport.clientHeight,
      rowHeight: this.rowHeight,
      loadedCount: layout.lineCount,
      overscan: this.overscan,
    });

    return {
      start: layout.startLine + range.start,
      end: layout.startLine + range.end,
    };
  },

  rebaseViewport() {
    if (this.state === null) return;

    const viewport = this.viewport();
    const rebased = rebaseScroll({
      segmentStartLine: this.segmentStartLine,
      scrollTop: viewport.scrollTop,
      viewportHeight: viewport.clientHeight,
      totalLines: this.state.totalLines,
      rowHeight: this.rowHeight,
      maxPhysicalHeight: this.maxPhysicalHeight,
    });

    this.segmentStartLine = rebased.segmentStartLine;
    if (viewport.scrollTop !== rebased.scrollTop) {
      viewport.scrollTop = rebased.scrollTop;
    }
  },

  nearLoadedEnd() {
    if (!this.state?.hasMore) return false;

    const viewport = this.viewport();
    const lastVisible = Math.ceil(
      (viewport.scrollTop + viewport.clientHeight) / this.rowHeight,
    );

    return (
      this.segmentStartLine + lastVisible >=
      this.state.loadedThrough - this.overscan
    );
  },

  markCurrentSourceLoaded() {
    this.el.querySelectorAll("[data-source]").forEach((button) => {
      button.dataset.loaded = String(button.dataset.source === this.source);
    });
  },

  viewport() {
    return this.el.querySelector("#proxy-rules-source-viewport");
  },

  spacer() {
    return this.el.querySelector("#proxy-rules-source-spacer");
  },

  rows() {
    return this.el.querySelector("#proxy-rules-source-rows");
  },

  setStatus(message) {
    this.statusMessage = boundedMessage(message);
    this.el.querySelector("#proxy-rules-viewer-loading").textContent =
      this.statusMessage;
  },

  setError(message) {
    this.errorMessage = boundedMessage(message);
    this.el.querySelector("#proxy-rules-viewer-error").textContent =
      this.errorMessage;
  },

  renderMessages() {
    this.el.querySelector("#proxy-rules-viewer-loading").textContent =
      this.statusMessage;
    this.el.querySelector("#proxy-rules-viewer-error").textContent =
      this.errorMessage;
  },
};

function boundedPageSize(value) {
  const size = Number(value);
  return Number.isInteger(size) && size >= 1 && size <= 500 ? size : 200;
}

function validSource(source) {
  return source === "gfwlist" || source === "local-proxy";
}

function boundedMessage(message) {
  return typeof message === "string" ? message.slice(0, 160) : "";
}

export default ProxyRulesSourceViewer;
