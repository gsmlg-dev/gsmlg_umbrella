import { afterEach, beforeEach, expect, test } from 'bun:test';

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
  expect(typeof adapter.mountLayout).toBe('function');
  adapter.mountLayout();
  adapter.mountLayout();
  expect(intersections).toHaveLength(1);
  intersections[0].callback([{ intersectionRatio: 0.25 }]);
  expect(nav.getAttribute('aria-hidden')).toBe('false');
  expect(nav.style.opacity).toBe(0.75);
  intersections[0].callback([{ intersectionRatio: 0.8 }]);
  expect(nav.getAttribute('aria-hidden')).toBe('true');
});

test('SPA replacement and persisted history restoration release and rebind header observers', () => {
  expect(typeof adapter.mountLayout).toBe('function');
  adapter.mountLayout();
  headers[0].isConnected = false;
  headers = [new Element({ 'data-nav-id': 'fixed-nav' })];
  mutations[0].callback();
  expect(intersections[0].disconnected).toBe(true);
  expect(intersections.filter((observer) => !observer.disconnected)).toHaveLength(1);
  window.dispatchEvent(new Event('pagehide'));
  expect(intersections.every((observer) => observer.disconnected)).toBe(true);
  expect(mutations[0].disconnected).toBe(true);
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  window.dispatchEvent(restored);
  expect(intersections.filter((observer) => !observer.disconnected)).toHaveLength(1);
});

test('shared theme menu restores storage, synchronizes radios and persists a selection', () => {
  expect(typeof adapter.mountLayout).toBe('function');
  storage.set('theme', 'moonlight');
  expect(adapter.mountLayout()).toBe('moonlight');
  expect(root.getAttribute('data-theme')).toBe('moonlight');
  expect(radios.map((radio) => radio.checked)).toEqual([false, false, true]);
  chooseTheme('sunshine');
  expect(storage.get('theme')).toBe('sunshine');
  expect(root.getAttribute('data-theme')).toBe('sunshine');
  expect(details.getAttribute('open')).toBe(null);
  chooseTheme('default');
  media.matches = true;
  media.dispatchEvent(new Event('change'));
  expect(root.getAttribute('data-theme')).toBe('moonlight');
  expect(storage.get('theme')).toBe('default');
  adapter.unmountLayout();
  media.matches = false;
  media.dispatchEvent(new Event('change'));
  expect(root.getAttribute('data-theme')).toBe('moonlight');
});

test('a fresh page bundle binds restored layout markup before Hologram replays any action', async () => {
  expect(typeof adapter.mountLayout).toBe('function');
  await import('../../assets/js/hologram/layout.mjs?restored-snapshot');
  expect(intersections).toHaveLength(1);
  adapter.mountLayout();
  expect(intersections).toHaveLength(1);
});
