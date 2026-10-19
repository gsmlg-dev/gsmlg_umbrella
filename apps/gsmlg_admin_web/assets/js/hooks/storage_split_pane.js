const MIN_TREE_WIDTH = 224;
const MIN_CONTENT_WIDTH = 320;
const KEYBOARD_STEP = 16;

const StorageSplitPane = {
  mounted() {
    this.preferredWidth = null;
    this.drag = null;
    this.desktop = window.matchMedia("(min-width: 1024px)");
    this.onBreakpointChange = () => this.syncWidth();
    this.desktop.addEventListener("change", this.onBreakpointChange);
    this.resizeObserver = new ResizeObserver(() => this.syncWidth());
    this.resizeObserver.observe(this.el);
    this.bindSplitter();
    this.syncWidth();
  },

  updated() {
    this.bindSplitter();
    this.syncWidth();
  },

  destroyed() {
    this.stopDragging();
    this.unbindSplitter();
    this.resizeObserver.disconnect();
    this.desktop.removeEventListener("change", this.onBreakpointChange);
  },

  bindSplitter() {
    const splitter = this.el.querySelector("[data-storage-splitter]");
    if (splitter === this.splitter) return;
    this.stopDragging();
    this.unbindSplitter();
    this.splitter = splitter;
    if (!splitter) return;

    this.splitterListeners = {
      pointerdown: (event) => {
        if (!this.desktop.matches || !event.isPrimary || event.button !== 0 || this.drag) return;
        event.preventDefault();
        splitter.focus();
        this.drag = { pointerId: event.pointerId, x: event.clientX, width: this.currentWidth };
        splitter.setPointerCapture(event.pointerId);
        this.el.classList.add("is-resizing");
      },
      pointermove: (event) => {
        if (!this.drag || event.pointerId !== this.drag.pointerId) return;
        this.setUserWidth(this.drag.width + event.clientX - this.drag.x);
      },
      pointerup: (event) => this.stopDragging(event),
      pointercancel: (event) => this.stopDragging(event),
      lostpointercapture: (event) => this.stopDragging(event),
      keydown: (event) => {
        if (!this.desktop.matches) return;
        const { min, max } = this.widthBounds();
        let width;
        switch (event.key) {
          case "ArrowLeft": width = this.currentWidth - KEYBOARD_STEP; break;
          case "ArrowRight": width = this.currentWidth + KEYBOARD_STEP; break;
          case "Home": width = min; break;
          case "End": width = max; break;
          default: return;
        }
        event.preventDefault();
        this.setUserWidth(width);
      },
    };
    for (const [type, listener] of Object.entries(this.splitterListeners)) {
      splitter.addEventListener(type, listener);
    }
  },

  unbindSplitter() {
    for (const [type, listener] of Object.entries(this.splitterListeners || {})) {
      this.splitter.removeEventListener(type, listener);
    }
    this.splitterListeners = null;
  },

  stopDragging(event) {
    if (!this.drag || (event && event.pointerId !== this.drag.pointerId)) return;
    const { pointerId } = this.drag;
    this.drag = null;
    this.el.classList.remove("is-resizing");
    if (this.splitter.hasPointerCapture(pointerId)) {
      this.splitter.releasePointerCapture(pointerId);
    }
  },

  widthBounds() {
    const available = Math.max(0, Math.floor(
      this.el.getBoundingClientRect().width - this.splitter.getBoundingClientRect().width - MIN_CONTENT_WIDTH,
    ));
    return { min: Math.min(MIN_TREE_WIDTH, available), max: available };
  },

  setUserWidth(width) {
    const { min, max } = this.widthBounds();
    this.preferredWidth = Math.min(max, Math.max(min, Math.round(width)));
    this.syncWidth();
  },

  syncWidth() {
    if (!this.desktop.matches) {
      this.stopDragging();
      this.el.style.removeProperty("--storage-tree-width");
      return;
    }
    if (!this.splitter || !this.el.querySelector("#storage-folder-tree")) return;

    const { min, max } = this.widthBounds();
    const defaultWidth = parseFloat(getComputedStyle(this.el).getPropertyValue("--storage-tree-default-width"));
    const requested = this.preferredWidth ?? (Number.isFinite(defaultWidth) ? defaultWidth : 320);
    this.currentWidth = Math.min(max, Math.max(min, Math.round(requested)));
    this.el.style.setProperty("--storage-tree-width", `${this.currentWidth}px`);
    this.splitter.setAttribute("aria-valuemin", `${min}`);
    this.splitter.setAttribute("aria-valuemax", `${max}`);
    this.splitter.setAttribute("aria-valuenow", `${this.currentWidth}`);
    this.splitter.setAttribute("aria-valuetext", `${this.currentWidth} pixels`);
  },
};

export default StorageSplitPane;
