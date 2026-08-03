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

export function appendPage(state, page) {
  if (!validPage(page)) throw new Error("invalid_page");
  if (state && state.version !== page.version)
    throw new Error("source_changed");

  const expectedStart = (state?.lines.length || 0) + 1;
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

  return {
    version: page.version,
    lines: [...(state?.lines || []), ...page.lines],
    nextCursor: page.next_cursor,
    hasMore: page.has_more,
    totalLines: page.total_lines,
  };
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
    this.pageSize = boundedPageSize(this.el.dataset.pageSize);
    this.state = null;
    this.source = this.selectedSource();
    this.activated = false;
    this.loading = false;
    this.requestSerial = 0;
    this.animationFrame = null;
    this.abortController = null;

    this.onScroll = () => {
      if (this.animationFrame !== null) return;

      this.animationFrame = requestAnimationFrame(() => {
        this.animationFrame = null;
        this.renderWindow();
        if (this.nearLoadedEnd()) this.loadNextPage();
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
        if (this.state === null) this.loadNextPage();
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
        if (reload) this.loadNextPage();
      },
    );

    this.updateSourceButtons();
    this.clearRenderedContent();
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
      if (!selected || this.state === null) button.dataset.loaded = "false";
    });
  },

  resetView({ preserveActivation = false } = {}) {
    this.requestSerial += 1;
    if (this.abortController) this.abortController.abort();

    this.abortController = null;
    this.loading = false;
    this.state = null;
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

  async loadNextPage({ retryOnConflict = true } = {}) {
    if (!this.activated || this.loading || (this.state && !this.state.hasMore))
      return;

    const source = this.source;
    const serial = this.requestSerial;
    const cursor = this.state?.nextCursor || null;
    const controller = new AbortController();
    this.abortController = controller;
    this.loading = true;
    this.setError("");
    this.setStatus("Loading source content…");

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

      if (response.status === 409 && retryOnConflict) {
        this.loading = false;
        this.abortController = null;
        this.resetView({ preserveActivation: true });
        this.setStatus("Source content changed. Reloading…");
        return this.loadNextPage({ retryOnConflict: false });
      }

      if (!response.ok) {
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
        this.state = appendPage(this.state, page);
      } catch (_error) {
        throw new Error("invalid_response");
      }

      this.markCurrentSourceLoaded();
      this.renderWindow();
      this.setStatus(
        `Loaded ${this.state.lines.length} of ${this.state.totalLines} lines.`,
      );
    } catch (error) {
      if (error?.name === "AbortError") return;
      if (serial !== this.requestSerial || source !== this.source) return;

      this.state = null;
      this.clearRenderedContent();
      this.updateSourceButtons();
      this.setError(
        error?.message === "invalid_response"
          ? "The source returned an invalid response."
          : "Source content could not be loaded.",
      );
    } finally {
      if (this.abortController === controller) {
        this.abortController = null;
        this.loading = false;

        if (this.state?.hasMore && this.nearLoadedEnd()) {
          queueMicrotask(() => this.loadNextPage());
        }
      }
    }
  },

  sourceUrl(source) {
    return source === "local-proxy"
      ? this.el.dataset.localProxyUrl
      : this.el.dataset.gfwlistUrl;
  },

  renderWindow() {
    if (this.state === null) return;

    const viewport = this.viewport();
    const range = visibleRange({
      scrollTop: viewport.scrollTop,
      viewportHeight: viewport.clientHeight,
      rowHeight: this.rowHeight,
      loadedCount: this.state.lines.length,
      overscan: this.overscan,
    });
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
      sourceText.textContent = this.state.lines[index];
      row.append(lineNumber, sourceText);
      fragment.appendChild(row);
    }

    this.spacer().style.height = `${this.state.totalLines * this.rowHeight}px`;
    this.rows().style.transform = `translateY(${range.start * this.rowHeight}px)`;
    this.rows().replaceChildren(fragment);
  },

  nearLoadedEnd() {
    if (!this.state?.hasMore) return false;

    const viewport = this.viewport();
    const lastVisible = Math.ceil(
      (viewport.scrollTop + viewport.clientHeight) / this.rowHeight,
    );

    return lastVisible >= this.state.lines.length - this.overscan;
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
    this.el.querySelector("#proxy-rules-viewer-loading").textContent = message;
  },

  setError(message) {
    this.el.querySelector("#proxy-rules-viewer-error").textContent = message;
  },
};

function boundedPageSize(value) {
  const size = Number(value);
  return Number.isInteger(size) && size >= 1 && size <= 500 ? size : 200;
}

function validSource(source) {
  return source === "gfwlist" || source === "local-proxy";
}

export default ProxyRulesSourceViewer;
