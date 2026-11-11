import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

const adapter = await import('../../assets/js/hologram/browser.mjs');

class Element extends EventTarget {
  constructor(attributes = {}) {
    super();
    this.attributes = new Map(Object.entries(attributes));
    this.isConnected = true;
    this.style = {};
    this.classList = {
      add: (name) => this.attributes.set(`class:${name}`, true),
      remove: (name) => this.attributes.delete(`class:${name}`),
    };
  }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  removeAttribute(name) { this.attributes.delete(name); }
}

let headers, nav, radios, details, root, mutations, intersections, media, storage;
beforeEach(() => {
  adapter.unmountLayout?.();
  headers = [new Element({ 'data-nav-id': 'fixed-nav' })];
  nav = new Element();
  details = new Element({ open: '' });
  radios = ['default', 'sunshine', 'moonlight'].map((value) => {
    const radio = new Element();
    radio.value = value;
    radio.matches = (selector) => selector === '.theme-controller-item';
    radio.closest = () => details;
    return radio;
  });
  root = new Element();
  mutations = [];
  intersections = [];
  media = new EventTarget();
  media.matches = false;
  storage = new Map();
  globalThis.document = Object.assign(new EventTarget(), {
    documentElement: root,
    querySelectorAll: (selector) => selector.includes('data-nav-id') ? headers : radios,
    getElementById: () => nav,
  });
  globalThis.window = new EventTarget();
  window.matchMedia = () => media;
  globalThis.localStorage = {
    getItem: (key) => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value),
  };
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; mutations.push(this); }
    observe() { this.disconnected = false; }
    disconnect() { this.disconnected = true; }
  };
  globalThis.IntersectionObserver = class {
    constructor(callback) { this.callback = callback; intersections.push(this); }
    observe(element) { this.target = element; }
    disconnect() { this.disconnected = true; }
  };
});

afterEach(() => {
  adapter.unmountLayout?.();
  for (const key of ['document', 'window', 'localStorage', 'MutationObserver', 'IntersectionObserver']) {
    delete globalThis[key];
  }
});

function chooseTheme(value) {
  const event = new Event('change');
  Object.defineProperty(event, 'target', { value: radios.find((radio) => radio.value === value) });
  document.dispatchEvent(event);
}

test('shared header shows its fixed navigation after scrolling without duplicate observers', () => {
  assert.strictEqual(typeof adapter.mountLayout, 'function');
  adapter.mountLayout();
  adapter.mountLayout();
  assert.strictEqual((intersections).length, 1);
  intersections[0].callback([{ intersectionRatio: 0.25 }]);
  assert.strictEqual(nav.getAttribute('aria-hidden'), 'false');
  assert.strictEqual(nav.style.opacity, 0.75);
  intersections[0].callback([{ intersectionRatio: 0.8 }]);
  assert.strictEqual(nav.getAttribute('aria-hidden'), 'true');
});

test('SPA replacement and persisted history restoration release and rebind header observers', () => {
  assert.strictEqual(typeof adapter.mountLayout, 'function');
  adapter.mountLayout();
  headers[0].isConnected = false;
  headers = [new Element({ 'data-nav-id': 'fixed-nav' })];
  mutations[0].callback();
  assert.strictEqual(intersections[0].disconnected, true);
  assert.strictEqual((intersections.filter((observer) => !observer.disconnected)).length, 1);
  window.dispatchEvent(new Event('pagehide'));
  assert.strictEqual(intersections.every((observer) => observer.disconnected), true);
  assert.strictEqual(mutations[0].disconnected, true);
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  window.dispatchEvent(restored);
  assert.strictEqual((intersections.filter((observer) => !observer.disconnected)).length, 1);
});

test('shared theme menu restores storage, synchronizes radios and persists a selection', () => {
  assert.strictEqual(typeof adapter.mountLayout, 'function');
  storage.set('theme', 'moonlight');
  assert.strictEqual(adapter.mountLayout(), 'moonlight');
  assert.strictEqual(root.getAttribute('data-theme'), 'moonlight');
  assert.deepStrictEqual(radios.map((radio) => radio.checked), [false, false, true]);
  chooseTheme('sunshine');
  assert.strictEqual(storage.get('theme'), 'sunshine');
  assert.strictEqual(root.getAttribute('data-theme'), 'sunshine');
  assert.strictEqual(details.getAttribute('open'), null);
  chooseTheme('default');
  media.matches = true;
  media.dispatchEvent(new Event('change'));
  assert.strictEqual(root.getAttribute('data-theme'), 'moonlight');
  assert.strictEqual(storage.get('theme'), 'default');
  adapter.unmountLayout();
  media.matches = false;
  media.dispatchEvent(new Event('change'));
  assert.strictEqual(root.getAttribute('data-theme'), 'moonlight');
});

test('a fresh page bundle binds restored layout markup before Hologram replays any action', async () => {
  assert.strictEqual(typeof adapter.mountLayout, 'function');
  await import('../../assets/js/hologram/layout.mjs?restored-snapshot');
  assert.strictEqual((intersections).length, 1);
  adapter.mountLayout();
  assert.strictEqual((intersections).length, 1);
});
