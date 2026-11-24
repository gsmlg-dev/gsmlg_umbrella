import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";
import { mountThemeColor } from "gsmlg_component/assets/js/theme_color.js";

let meta, root, observers, primary, context, lifecycle;

function element(attributes = {}) {
  return {
    attributes: new Map(Object.entries(attributes)),
    getAttribute(name) { return this.attributes.get(name) ?? null; },
    setAttribute(name, value) { this.attributes.set(name, value); },
  };
}

beforeEach(() => {
  meta = element({ content: "" });
  root = element({ "data-theme": "sunshine" });
  observers = [];
  primary = "oklch(60% 0.2 30)";
  context = {
    fillStyle: "",
    clearRect() {},
    fillRect() {},
    getImageData: () => ({ data: [225, 70, 53, 255] }),
  };
  globalThis.document = Object.assign(new EventTarget(), {
    documentElement: root,
    createElement: () => ({ getContext: () => context }),
    querySelector: () => meta,
  });
  globalThis.window = new EventTarget();
  globalThis.getComputedStyle = () => ({ getPropertyValue: () => primary });
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(target, options) { this.target = target; this.options = options; }
    disconnect() { this.disconnected = true; }
  };
});

afterEach(() => {
  lifecycle?.dispose();
  lifecycle = undefined;
  for (const key of ["document", "window", "getComputedStyle", "MutationObserver"]) delete globalThis[key];
});

test("initial color uses the active Duskmoon token and converts it to browser chrome sRGB", () => {
  lifecycle = mountThemeColor();
  assert.equal(context.fillStyle, primary);
  assert.equal(meta.getAttribute("content"), "#e14635");
  assert.equal(observers[0].target, root);
  assert.deepEqual(observers[0].options.attributeFilter, ["data-theme"]);

  assert.equal(mountThemeColor(), lifecycle);
  assert.equal(observers.length, 1);
});

test("theme changes update chrome independently of system light or dark preference", () => {
  lifecycle = mountThemeColor();
  primary = "oklch(80% 0.15 240)";
  root.setAttribute("data-theme", "moonlight");
  context.getImageData = () => ({ data: [90, 195, 250, 255] });
  observers[0].callback();
  assert.equal(context.fillStyle, primary);
  assert.equal(meta.getAttribute("content"), "#5ac3fa");
});

test("stylesheet load and restored navigation resynchronize newly inserted metadata", () => {
  primary = "";
  lifecycle = mountThemeColor();
  assert.equal(meta.getAttribute("content"), "");

  primary = "oklch(60% 0.2 30)";
  document.dispatchEvent(new Event("load"));
  assert.equal(meta.getAttribute("content"), "#e14635");

  meta = element({ content: "" });
  window.dispatchEvent(new Event("pageshow"));
  assert.equal(meta.getAttribute("content"), "#e14635");
  lifecycle.dispose();
  assert.equal(observers[0].disconnected, true);
});
