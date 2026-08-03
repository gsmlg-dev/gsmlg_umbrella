export function sourcePageUrl(base, cursor, limit) {
  const params = new URLSearchParams({ limit: String(limit) });
  if (cursor) params.set("cursor", cursor);
  return `${base}?${params.toString()}`;
}

const ERROR_MESSAGES = {
  404: "Source content was not found.",
  409: "Source content changed. Try again.",
  422: "The source page could not be loaded.",
  503: "Source content is temporarily unavailable.",
};

const ProxyRulesSourceViewer = {
  mounted() {
    this.pageSize = boundedPageSize(this.el.dataset.pageSize);
    this.source = this.selectedSource();
    this.cache = new Map();
    this.activated = false;
    this.loading = false;
    this.requestGeneration = 0;
    this.abortController = null;
    this.statusMessage = "";
    this.errorMessage = "";
    this.sourceVersions = this.currentSourceVersions();
    this.requestVersion = null;

    this.onClick = (event) => {
      const sourceButton = event.target.closest?.("[data-source]");
      if (sourceButton && this.el.contains(sourceButton)) {
        this.switchSource(sourceButton.dataset.source);
        return;
      }

      const viewButton = event.target.closest?.("#proxy-rules-view-content");
      if (viewButton && this.el.contains(viewButton)) {
        this.activated = true;
        this.loadSource();
      }
    };

    this.el.addEventListener("click", this.onClick);
    this.sourceChangedRef = this.handleEvent(
      "proxy-rules:source-changed",
      ({ source }) => this.invalidateSource(source),
    );

    this.updateSourceButtons();
    this.renderSelectedSource();
  },

  updated() {
    this.reconcileSourceVersions();
    this.updateSourceButtons();
    this.updateLoadingButton();
    this.renderMessages();
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.cancelRequest();
    if (this.sourceChangedRef !== undefined) {
      this.removeHandleEvent?.(this.sourceChangedRef);
    }
  },

  selectedSource() {
    const selected = this.el.querySelector('[data-source][aria-pressed="true"]')
      ?.dataset.source;
    return validSource(selected) ? selected : "gfwlist";
  },

  switchSource(source) {
    if (!validSource(source) || source === this.source) return;

    this.cancelRequest();
    this.source = source;
    this.activated = this.cache.has(source);
    this.setError("");
    this.setStatus("");
    this.updateSourceButtons();
    this.renderSelectedSource();
  },

  invalidateSource(source) {
    if (!validSource(source)) return;

    this.cache.delete(source);
    if (source !== this.source) {
      this.updateSourceButtons();
      return;
    }

    const reload = this.activated;
    this.cancelRequest();
    this.content().textContent = "";
    this.updateSourceButtons();
    if (reload) this.loadSource();
  },

  updateSourceButtons() {
    this.el.querySelectorAll("[data-source]").forEach((button) => {
      const source = button.dataset.source;
      const selected = source === this.source;
      button.setAttribute("aria-pressed", String(selected));
      button.setAttribute("variant", selected ? "secondary" : "outline");
      button.dataset.loaded = String(this.cache.has(source));
    });
  },

  currentSourceVersions() {
    return new Map(
      [...this.el.querySelectorAll("[data-source]")].map((button) => [
        button.dataset.source,
        button.dataset.version || "",
      ]),
    );
  },

  sourceVersion(source) {
    const button = [...this.el.querySelectorAll("[data-source]")].find(
      (candidate) => candidate.dataset.source === source,
    );
    return button?.dataset.version || "";
  },

  reconcileSourceVersions() {
    let selectedMismatch = false;
    let reloadSelected = false;

    this.el.querySelectorAll("[data-source]").forEach((button) => {
      const source = button.dataset.source;
      const version = button.dataset.version || "";
      const versionChanged = this.sourceVersions.get(source) !== version;
      const cached = this.cache.get(source);
      const cachedMismatch = cached && cached.version !== version;
      const requestMismatch =
        source === this.source &&
        this.loading &&
        this.requestVersion !== version;

      if (cachedMismatch) this.cache.delete(source);
      if (
        source === this.source &&
        (cachedMismatch || requestMismatch || (versionChanged && this.activated))
      ) {
        selectedMismatch = true;
        reloadSelected = this.activated;
      }

      this.sourceVersions.set(source, version);
    });

    if (!selectedMismatch) {
      this.renderSelectedSource();
      return;
    }

    this.cancelRequest();
    this.content().textContent = "";
    this.setStatus("");
    this.setError("");
    if (reloadSelected) this.loadSource();
  },

  renderSelectedSource() {
    const cached = this.cache.get(this.source);
    this.content().textContent = cached ? cached.content : "";
  },

  async loadSource({ conflictRetryUsed = false } = {}) {
    if (!this.activated || this.loading || this.cache.has(this.source)) {
      this.renderSelectedSource();
      return;
    }

    const source = this.source;
    const generation = this.requestGeneration;
    const controller = new AbortController();
    this.abortController = controller;
    this.requestVersion = this.sourceVersion(source);
    this.setLoading(true);
    this.setError("");
    this.setStatus("Loading source content…");

    try {
      const complete = await this.fetchCompleteSource(
        source,
        generation,
        controller,
      );
      if (!this.currentRequest(source, generation, controller)) return;
      if (!this.versionMatchesMetadata(source, complete.version)) {
        throw new Error("source_changed");
      }

      this.cache.set(source, complete);
      this.renderSelectedSource();
      this.updateSourceButtons();
      this.setStatus(loadedMessage(complete.totalLines));
    } catch (error) {
      if (error?.name === "AbortError") return;
      if (!this.currentRequest(source, generation, controller)) return;

      if (error?.message === "source_changed" && !conflictRetryUsed) {
        this.finishRequest(controller);
        this.setStatus("Source content changed. Reloading…");
        return this.loadSource({ conflictRetryUsed: true });
      }

      this.setStatus("");
      this.setError(errorMessage(error));
    } finally {
      this.finishRequest(controller);
    }
  },

  async fetchCompleteSource(source, generation, controller) {
    let cursor = null;
    let version = null;
    let totalLines = null;
    let endsWithNewline = null;
    const lines = [];

    do {
      const response = await fetch(
        sourcePageUrl(this.sourceUrl(source), cursor, this.pageSize),
        {
          credentials: "same-origin",
          headers: { Accept: "application/json" },
          signal: controller.signal,
        },
      );

      if (!this.currentRequest(source, generation, controller)) {
        throw abortError();
      }
      if (response.status === 409) throw new Error("source_changed");
      if (!response.ok) {
        const error = new Error("request_failed");
        error.status = response.status;
        throw error;
      }

      let page;
      try {
        page = await response.json();
      } catch (_error) {
        throw new Error("invalid_response");
      }

      validatePage(page, {
        version,
        totalLines,
        endsWithNewline,
        loadedLines: lines.length,
      });
      version = page.version;
      totalLines = page.total_lines;
      endsWithNewline = page.ends_with_newline;
      lines.push(...page.lines);
      cursor = page.next_cursor;
    } while (cursor !== null);

    return {
      version,
      totalLines,
      content: lines.join("\n") + (endsWithNewline ? "\n" : ""),
    };
  },

  versionMatchesMetadata(source, version) {
    const metadataVersion = this.sourceVersion(source);
    return metadataVersion === "" || metadataVersion === version;
  },

  currentRequest(source, generation, controller) {
    return (
      source === this.source &&
      generation === this.requestGeneration &&
      controller === this.abortController
    );
  },

  finishRequest(controller) {
    if (this.abortController !== controller) return;
    this.abortController = null;
    this.requestVersion = null;
    this.setLoading(false);
  },

  cancelRequest() {
    this.requestGeneration += 1;
    this.abortController?.abort();
    this.abortController = null;
    this.requestVersion = null;
    this.setLoading(false);
  },

  sourceUrl(source) {
    if (source === "local-proxy") return this.el.dataset.localProxyUrl;
    if (source === "local-direct") return this.el.dataset.localDirectUrl;
    return this.el.dataset.gfwlistUrl;
  },

  content() {
    return this.el.querySelector("#proxy-rules-source-content");
  },

  setLoading(loading) {
    this.loading = loading;
    this.updateLoadingButton();
  },

  updateLoadingButton() {
    const button = this.el.querySelector("#proxy-rules-view-content");
    button.setAttribute("aria-disabled", String(this.loading));

    if (this.loading) {
      button.setAttribute("disabled", "");
    } else {
      button.removeAttribute("disabled");
    }
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

function validatePage(
  page,
  { version, totalLines, endsWithNewline, loadedLines },
) {
  const validShape =
    page !== null &&
    typeof page === "object" &&
    /^[0-9a-f]{64}$/.test(page.version) &&
    Number.isSafeInteger(page.start_line) &&
    page.start_line === loadedLines + 1 &&
    Array.isArray(page.lines) &&
    page.lines.every((line) => typeof line === "string") &&
    Number.isSafeInteger(page.total_lines) &&
    page.total_lines >= 0 &&
    typeof page.ends_with_newline === "boolean" &&
    typeof page.has_more === "boolean" &&
    (page.next_cursor === null ||
      (typeof page.next_cursor === "string" && page.next_cursor.length > 0));

  if (!validShape) throw new Error("invalid_response");
  if (version !== null && version !== page.version) {
    throw new Error("source_changed");
  }
  if (totalLines !== null && totalLines !== page.total_lines) {
    throw new Error("invalid_response");
  }
  if (
    endsWithNewline !== null &&
    endsWithNewline !== page.ends_with_newline
  ) {
    throw new Error("invalid_response");
  }

  const nextLoaded = loadedLines + page.lines.length;
  const validContinuation = page.has_more
    ? page.next_cursor !== null &&
      page.lines.length > 0 &&
      nextLoaded < page.total_lines
    : page.next_cursor === null && nextLoaded === page.total_lines;
  if (!validContinuation) throw new Error("invalid_response");
}

function boundedPageSize(value) {
  const size = Number(value);
  return Number.isInteger(size) && size >= 1 && size <= 500 ? size : 200;
}

function validSource(source) {
  return ["gfwlist", "local-proxy", "local-direct"].includes(source);
}

function boundedMessage(message) {
  return typeof message === "string" ? message.slice(0, 160) : "";
}

function loadedMessage(count) {
  return count === 1
    ? "Loaded all 1 line."
    : `Loaded all ${count} lines.`;
}

function errorMessage(error) {
  if (error?.message === "invalid_response") {
    return "The source returned an invalid response.";
  }
  if (error?.message === "source_changed") return ERROR_MESSAGES[409];
  return (
    ERROR_MESSAGES[error?.status] || "Source content could not be loaded."
  );
}

function abortError() {
  const error = new Error("aborted");
  error.name = "AbortError";
  return error;
}

export default ProxyRulesSourceViewer;
