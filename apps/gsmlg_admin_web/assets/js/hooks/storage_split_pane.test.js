import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, test } from "node:test";

import StorageSplitPane from "./storage_split_pane.js";

let originals;
let media;
let observers;
let mounted;

beforeEach(() => {
  originals = {
    window: globalThis.window,
    document: globalThis.document,
    getComputedStyle: globalThis.getComputedStyle,
    ResizeObserver: globalThis.ResizeObserver,
  };
  media = target({ matches: true });
  observers = [];
  mounted = [];
  globalThis.window = { matchMedia: () => media };
  globalThis.document = { activeElement: null };
  globalThis.getComputedStyle = (el) => ({
    getPropertyValue: () => `${el.defaultWidth}px`,
  });
  globalThis.ResizeObserver = class {
    constructor(callback) {
      this.callback = callback;
      observers.push(this);
    }
    observe(el) { this.el = el; }
    disconnect() { this.disconnected = true; }
  };
});

afterEach(() => {
  for (const hook of mounted) hook.destroyed();
  Object.assign(globalThis, originals);
});

describe("storage split pane hook", () => {
  test("uses responsive CSS defaults and publishes accessible pixel bounds", () => {
    const { root, splitter, width } = setup();
    assert.strictEqual(width(), "320px");
    for (const [name, value] of Object.entries({
      "aria-valuemin": "224",
      "aria-valuemax": "868",
      "aria-valuenow": "320",
      "aria-valuetext": "320 pixels",
    })) {
      assert.strictEqual(splitter.attributes[name], value);
    }
    root.defaultWidth = 384;
    observers[0].callback();
    assert.strictEqual(width(), "384px");
  });

  test("drags using pointer capture and ignores unrelated pointer input", () => {
    const { root, splitter, width } = setup();
    splitter.dispatch("pointerdown", event({ button: 2 }));
    splitter.dispatch("pointerdown", event({ isPrimary: false }));
    assert.strictEqual(splitter.captured.size, 0);
    const down = event({ clientX: 400 });
    splitter.dispatch("pointerdown", down);
    assert.strictEqual(down.defaultPrevented, true);
    assert.strictEqual(splitter.captured.has(1), true);
    assert.strictEqual(root.classList.contains("is-resizing"), true);
    splitter.dispatch("pointermove", event({ pointerId: 2, clientX: 600 }));
    assert.strictEqual(width(), "320px");
    splitter.dispatch("pointermove", event({ clientX: 550 }));
    assert.strictEqual(width(), "470px");
    splitter.dispatch("pointerup", event());
    assert.strictEqual(splitter.captured.size, 0);
    assert.strictEqual(root.classList.contains("is-resizing"), false);
    splitter.dispatch("pointermove", event({ clientX: 800 }));
    assert.strictEqual(width(), "470px");
  });

  test("clamps dragging and supports keyboard sizing without blocking other keys", () => {
    const { splitter, width } = setup();
    splitter.dispatch("pointerdown", event({ clientX: 400 }));
    splitter.dispatch("pointermove", event({ clientX: -1000 }));
    assert.strictEqual(width(), "224px");
    splitter.dispatch("pointermove", event({ clientX: 2000 }));
    assert.strictEqual(width(), "868px");
    splitter.dispatch("pointerup", event());
    const key = (key) => {
      const e = event({ key });
      splitter.dispatch("keydown", e);
      return e;
    };
    assert.strictEqual(key("Home").defaultPrevented, true);
    assert.strictEqual(width(), "224px");
    key("ArrowRight");
    assert.strictEqual(width(), "240px");
    key("ArrowLeft");
    assert.strictEqual(width(), "224px");
    key("End");
    assert.strictEqual(width(), "868px");
    assert.strictEqual(key("Tab").defaultPrevented, false);
    assert.strictEqual(key("Enter").defaultPrevented, false);
  });

  test("a valid drag focuses the separator so keyboard sizing continues there", () => {
    const { splitter, width } = setup();
    const previousFocus = {};
    document.activeElement = previousFocus;
    splitter.dispatch("pointerdown", event({ button: 2 }));
    splitter.dispatch("pointerdown", event({ isPrimary: false }));
    assert.strictEqual(document.activeElement, previousFocus);
    splitter.dispatch("pointerdown", event());
    splitter.dispatch("pointermove", event({ clientX: 450 }));
    splitter.dispatch("pointerup", event());
    assert.strictEqual(document.activeElement, splitter);
    document.activeElement.dispatch("keydown", event({ key: "ArrowRight" }));
    assert.strictEqual(width(), "386px");
  });

  test("retains user width through LiveView updates and temporary container shrink", () => {
    const { hook, root, splitter, width } = setup();
    splitter.dispatch("pointerdown", event({ clientX: 400 }));
    splitter.dispatch("pointermove", event({ clientX: 600 }));
    splitter.dispatch("pointerup", event());
    root.style.removeProperty("--storage-tree-width");
    splitter.attributes = {};
    hook.updated();
    assert.strictEqual(width(), "520px");
    assert.strictEqual(splitter.attributes["aria-valuenow"], "520");
    root.width = 700;
    observers[0].callback();
    assert.strictEqual(width(), "368px");
    root.width = 1200;
    observers[0].callback();
    assert.strictEqual(width(), "520px");
    root.width = 500;
    observers[0].callback();
    assert.strictEqual(width(), "168px");
    assert.strictEqual(splitter.attributes["aria-valuemin"], "168");
  });

  test("mobile disables resizing, ends active drag, and restores desktop width", () => {
    const { root, splitter, width } = setup();
    splitter.dispatch("keydown", event({ key: "ArrowRight" }));
    splitter.dispatch("pointerdown", event());
    media.matches = false;
    media.dispatch("change", {});
    assert.strictEqual(width(), undefined);
    assert.strictEqual(root.classList.contains("is-resizing"), false);
    assert.strictEqual(splitter.captured.size, 0);
    const key = event({ key: "ArrowRight" });
    splitter.dispatch("keydown", key);
    splitter.dispatch("pointerdown", event());
    assert.strictEqual(key.defaultPrevented, false);
    assert.strictEqual(splitter.captured.size, 0);
    media.matches = true;
    media.dispatch("change", {});
    assert.strictEqual(width(), "336px");
  });

  test("mounting on mobile leaves the stacked layout to CSS", () => {
    media.matches = false;
    const { splitter, width } = setup();
    splitter.dispatch("pointerdown", event());
    assert.strictEqual(width(), undefined);
    assert.strictEqual(splitter.captured.size, 0);
    media.matches = true;
    media.dispatch("change", {});
    assert.strictEqual(width(), "320px");
  });

  test("a replacement separator receives listeners and width after a patch", () => {
    const { hook, root, splitter, width } = setup();
    splitter.dispatch("keydown", event({ key: "ArrowRight" }));
    splitter.dispatch("pointerdown", event());
    const replacement = createSplitter();
    root.splitter = replacement;
    hook.updated();
    assert.strictEqual(splitter.listenerCount(), 0);
    assert.strictEqual(splitter.captured.size, 0);
    assert.strictEqual(root.classList.contains("is-resizing"), false);
    assert.strictEqual(replacement.attributes["aria-valuenow"], "336");
    replacement.dispatch("keydown", event({ key: "ArrowRight" }));
    assert.strictEqual(width(), "352px");
  });

  test("cancel, lost capture, and destroy clean up dragging and listeners", () => {
    const { hook, root, splitter } = setup();
    for (const type of ["pointercancel", "lostpointercapture"]) {
      splitter.dispatch("pointerdown", event());
      splitter.dispatch(type, event());
      assert.strictEqual(root.classList.contains("is-resizing"), false);
      assert.strictEqual(splitter.captured.size, 0);
    }
    splitter.dispatch("pointerdown", event());
    hook.destroyed();
    assert.strictEqual(root.classList.contains("is-resizing"), false);
    assert.strictEqual(splitter.captured.size, 0);
    assert.strictEqual(splitter.listenerCount(), 0);
    assert.strictEqual(media.listenerCount(), 0);
    assert.strictEqual(observers[0].disconnected, true);
  });
});

function setup() {
  const splitter = createSplitter();
  const styles = new Map();
  const classes = new Set();
  const root = {
    width: 1200,
    defaultWidth: 320,
    splitter,
    style: {
      setProperty: (name, value) => styles.set(name, value),
      removeProperty: (name) => styles.delete(name),
    },
    classList: {
      add: (name) => classes.add(name),
      remove: (name) => classes.delete(name),
      contains: (name) => classes.has(name),
    },
    querySelector: (selector) => selector === "[data-storage-splitter]" ? root.splitter : {},
    getBoundingClientRect: () => ({ width: root.width }),
  };
  const hook = { ...StorageSplitPane, el: root };
  hook.mounted();
  mounted.push(hook);
  return { hook, root, splitter, width: () => styles.get("--storage-tree-width") };
}

function createSplitter() {
  const splitter = target({ width: 12, attributes: {}, captured: new Set() });
  splitter.focus = () => { document.activeElement = splitter; };
  splitter.setAttribute = (name, value) => { splitter.attributes[name] = value; };
  splitter.getBoundingClientRect = () => ({ width: splitter.width });
  splitter.setPointerCapture = (id) => splitter.captured.add(id);
  splitter.hasPointerCapture = (id) => splitter.captured.has(id);
  splitter.releasePointerCapture = (id) => {
    splitter.captured.delete(id);
    splitter.dispatch("lostpointercapture", event({ pointerId: id }));
  };
  return splitter;
}

function target(properties = {}) {
  const listeners = new Map();
  return {
    ...properties,
    addEventListener(type, callback) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(callback);
    },
    removeEventListener(type, callback) { listeners.get(type)?.delete(callback); },
    dispatch(type, event) {
      for (const callback of listeners.get(type) || []) callback(event);
    },
    listenerCount() {
      return [...listeners.values()].reduce((count, callbacks) => count + callbacks.size, 0);
    },
  };
}

function event(properties = {}) {
  return {
    pointerId: 1,
    clientX: 400,
    button: 0,
    isPrimary: true,
    defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; },
    ...properties,
  };
}
