import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

import { register } from "node:module";
import { resources } from "../../../../scripts/test/browser-three.mjs";

register(new URL("../../../../scripts/test/browser-module-loader.mjs", import.meta.url));

const adapter = await import('../../assets/js/hologram/browser.mjs');

class Element extends EventTarget {
  constructor() {
    super();
    this.attributes = new Map();
    this.isConnected = true;
    this.style = {};
    this.classList = {
      remove: (name) => this.attributes.delete(`class:${name}`),
      add: (name) => this.attributes.set(`class:${name}`, true),
    };
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); }
  remove() { this.isConnected = false; }
}

let nodes, observers, frames, cancelled, body, parsedSvg, parseError, measuredSvg;
beforeEach(() => {
  nodes = new Map();
  observers = [];
  frames = new Map();
  cancelled = [];
  resources.length = 0;
  parseError = false;
  parsedSvg = new Element();
  parsedSvg.localName = 'svg';
  parsedSvg.namespaceURI = 'http://www.w3.org/2000/svg';
  parsedSvg.setAttribute('width', '100');
  parsedSvg.setAttribute('height', '100');
  measuredSvg = { getBBox: () => ({ x: 2, y: 3, width: 20, height: 30 }) };
  body = { children: [], appendChild(node) { this.children.push(node); return node; } };
  globalThis.document = {
    body,
    getElementById: (id) => nodes.get(id) ?? null,
    querySelectorAll: () => [...nodes.values()].filter((node) =>
      node.isConnected && node.getAttribute('data-hologram-screensaver-video') !== null),
    createElement: (tag) => {
      const node = new Element();
      if (tag === 'iframe') node.contentDocument = {
        body: { appendChild() {} },
        importNode: () => measuredSvg,
      };
      return node;
    },
  };
  globalThis.window = new EventTarget();
  globalThis.screen = { width: 1280, height: 720 };
  globalThis.requestAnimationFrame = (fn) => {
    const id = frames.size + 1;
    frames.set(id, fn);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => { cancelled.push(id); frames.delete(id); };
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe() {}
    disconnect() { this.disconnected = true; }
  };
  globalThis.DOMParser = class {
    parseFromString() {
      return {
        documentElement: parsedSvg,
        querySelector: (selector) => selector === 'parsererror' && parseError ? {} : null,
      };
    }
  };
  globalThis.XMLSerializer = class {
    serializeToString(svg) {
      return `<svg viewBox="${svg.getAttribute('viewBox')}"${svg.getAttribute('width') ? ' width="100"' : ''}${svg.getAttribute('height') ? ' height="100"' : ''}/>`;
    }
  };
});

afterEach(() => {
  for (const id of ['canvas', 'other']) adapter.unmountScreensaver?.(id);
});

test('map updates preserve coordinates on the equator and center longitude zero', async () => {
  assert.strictEqual(typeof adapter.updateMap, 'function');
  const map = new Element();
  nodes.set('map', map);
  assert.strictEqual(await adapter.mountMap('map'), true);
  assert.strictEqual(adapter.updateMap('map', [[0, 0], [2, 0]], 0), true);
  assert.strictEqual(map.getAttribute('points'), '[[0,0],[2,0]]');
  assert.strictEqual(map.getAttribute('center-longitude'), '0');
  assert.strictEqual(adapter.updateMap('missing', []), false);
});

test('SVG measurement uses a script-disabled sandbox and removes temporary DOM', async () => {
  assert.strictEqual(typeof adapter.autocropSvg, 'function');
  const pending = adapter.autocropSvg('<svg width="100" height="100"/>');
  assert.strictEqual(body.children[0].getAttribute('sandbox'), 'allow-same-origin');
  for (const fn of [...frames.values()]) fn();
  assert.deepStrictEqual(await pending, { ok: true, output: '<svg viewBox="2 3 20 30"/>', error: '' });
  assert.strictEqual(body.children[0].isConnected, false);
});

test('malformed SVG is reported without attaching a measurement frame', async () => {
  assert.strictEqual(typeof adapter.autocropSvg, 'function');
  parseError = true;
  assert.strictEqual((await adapter.autocropSvg('<svg')).ok, false);
  assert.strictEqual((body.children).length, 0);
});

test('SVG measurement failure removes the frame and resolves an error envelope', async () => {
  assert.strictEqual(typeof adapter.autocropSvg, 'function');
  measuredSvg.getBBox = () => { throw new Error('Cannot measure SVG'); };
  const pending = adapter.autocropSvg('<svg/>');
  for (const fn of [...frames.values()]) fn();
  assert.deepStrictEqual(await pending, { ok: false, output: '', error: 'Cannot measure SVG' });
  assert.strictEqual(body.children[0].isConnected, false);
});

function screenElements() {
  const canvas = new Element();
  canvas.id = 'canvas';
  const tracks = [{ stopped: false, stop() { this.stopped = true; } }];
  canvas.captureStream = () => ({ getTracks: () => tracks });
  const video = new Element();
  video.play = async () => {};
  video.pause = () => { video.paused = true; };
  video.requestFullscreen = async () => {};
  nodes.set('canvas', canvas);
  nodes.set('video', video);
  return { canvas, video, tracks };
}

test('screensaver releases WebGL resources, animation and media on navigation', async () => {
  assert.strictEqual(typeof adapter.mountScreensaver, 'function');
  const { canvas, video, tracks } = screenElements();
  assert.strictEqual(await adapter.mountScreensaver('canvas', 'video'), true);
  assert.strictEqual(await adapter.startFullscreen('canvas'), true);
  assert.ok(video.srcObject);
  canvas.isConnected = false;
  observers[0].callback();
  assert.strictEqual(resources.every((resource) => resource.disposed), true);
  assert.strictEqual(tracks[0].stopped, true);
  assert.strictEqual(video.srcObject, null);
  assert.strictEqual(video.paused, true);
  assert.strictEqual((cancelled).length, 1);
  assert.strictEqual(adapter.unmountScreensaver('canvas'), false);
  assert.strictEqual(observers[0].disconnected, true);
});

test('remounting the same canvas leaves a single animation and pagehide cleans it up', async () => {
  assert.strictEqual(typeof adapter.mountScreensaver, 'function');
  screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.mountScreensaver('canvas', 'video');
  assert.strictEqual(frames.size, 1);
  window.dispatchEvent(new Event('pagehide'));
  assert.strictEqual(resources.every((resource) => resource.disposed), true);
  assert.strictEqual(frames.size, 0);
});

test('fullscreen rejection stops the captured tracks and hides video', async () => {
  const { video, tracks } = screenElements();
  video.requestFullscreen = async () => { throw new Error('Denied'); };
  await adapter.mountScreensaver('canvas', 'video');
  assert.strictEqual(await adapter.startFullscreen('canvas'), false);
  assert.strictEqual(tracks[0].stopped, true);
  assert.strictEqual(video.srcObject, null);
  assert.strictEqual(video.attributes.has('class:hidden'), true);
});

test('fullscreen exit stops captured media while retaining the embedded animation', async () => {
  const { video, tracks } = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.startFullscreen('canvas');
  document.fullscreenElement = video;
  video.dispatchEvent(new Event('fullscreenchange'));
  assert.deepStrictEqual(resources[0].size, [1280, 720]);
  document.fullscreenElement = null;
  video.dispatchEvent(new Event('fullscreenchange'));
  assert.deepStrictEqual(resources[0].size, [640, 320]);
  assert.strictEqual(tracks[0].stopped, true);
  assert.strictEqual(frames.size, 1);
});

test('concurrent setup only starts the most recent screensaver', async () => {
  screenElements();
  const first = adapter.mountScreensaver('canvas', 'video');
  const second = adapter.mountScreensaver('canvas', 'video');
  assert.strictEqual(await first, false);
  assert.strictEqual(await second, true);
  assert.strictEqual(frames.size, 1);
  assert.strictEqual((resources).length, 4);
});

function notifyDomChanges() {
  for (const observer of [...observers]) {
    if (!observer.disconnected) observer.callback();
  }
}

async function settleMount() {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

test('history reinsertion restores a disposed screensaver without duplicating a pending mount', async () => {
  const original = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.startFullscreen('canvas');
  original.canvas.isConnected = false;
  original.video.isConnected = false;
  nodes.clear();
  notifyDomChanges();
  assert.strictEqual(frames.size, 0);
  assert.strictEqual(resources.every((resource) => resource.disposed), true);
  assert.strictEqual(original.tracks[0].stopped, true);

  const restored = screenElements();
  notifyDomChanges();
  notifyDomChanges();
  await settleMount();
  assert.strictEqual(frames.size, 1);
  assert.strictEqual((resources.filter((resource) => !resource.disposed)).length, 4);
  assert.strictEqual(await adapter.startFullscreen('canvas'), true);
  assert.ok(restored.video.srcObject);
});

test('persisted pageshow remounts after pagehide and repeated restoration stays singular', async () => {
  const { tracks } = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.startFullscreen('canvas');
  window.dispatchEvent(new Event('pagehide'));
  assert.strictEqual(frames.size, 0);
  assert.strictEqual(tracks[0].stopped, true);
  assert.strictEqual(resources.every((resource) => resource.disposed), true);
  notifyDomChanges();
  await settleMount();
  assert.strictEqual(frames.size, 0);

  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  window.dispatchEvent(restored);
  notifyDomChanges();
  await settleMount();
  assert.strictEqual(frames.size, 1);
  assert.strictEqual((resources).length, 8);
  assert.strictEqual((resources.filter((resource) => !resource.disposed)).length, 4);
  assert.strictEqual(await adapter.startFullscreen('canvas'), true);
});

test('explicit unmount cancels restoration and disconnects its native lifecycle watcher', async () => {
  screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  assert.strictEqual(adapter.unmountScreensaver('canvas'), true);
  notifyDomChanges();
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  await settleMount();
  assert.strictEqual(frames.size, 0);
  assert.strictEqual((resources).length, 4);
  assert.strictEqual(observers.every((observer) => observer.disconnected), true);
});

test('pagehide during async setup cannot let a stale mount replace the restored renderer', async () => {
  screenElements();
  const originalMount = adapter.mountScreensaver('canvas', 'video');
  window.dispatchEvent(new Event('pagehide'));
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  notifyDomChanges();
  assert.strictEqual(await originalMount, false);
  await settleMount();
  assert.strictEqual(frames.size, 1);
  assert.strictEqual((resources).length, 4);
  assert.strictEqual(await adapter.startFullscreen('canvas'), true);
});

test('a later page bundle controls and disposes the screensaver restored by an earlier bundle', async () => {
  const original = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  original.canvas.isConnected = false;
  original.video.isConnected = false;
  nodes.clear();
  notifyDomChanges();

  // Hologram registers the next page's separately bundled adapter functions,
  // then Back restores component state without restoring those JS bindings.
  const nextPageAdapter = await import('../../assets/js/hologram/browser.mjs?next-page-bundle');
  assert.notStrictEqual(nextPageAdapter.startFullscreen, adapter.startFullscreen);
  const restored = screenElements();
  notifyDomChanges();
  await settleMount();
  assert.strictEqual(frames.size, 1);
  assert.strictEqual(await nextPageAdapter.startFullscreen('canvas'), true);
  assert.ok(restored.video.srcObject);
  assert.strictEqual(nextPageAdapter.unmountScreensaver('canvas'), true);
  assert.strictEqual(frames.size, 0);
  assert.strictEqual(resources.every((resource) => resource.disposed), true);
  assert.strictEqual(observers.every((observer) => observer.disconnected), true);
});

async function inFreshDocument(suffix, verify) {
  // A document navigation loses JS module state while Hologram can restore
  // ready=true from storage without replaying the original setup action.
  const key = Symbol.for('gsmlg.toolbox.screensavers');
  const previousState = globalThis[key];
  delete globalThis[key];
  let freshAdapter;
  try {
    freshAdapter = await import(`../../assets/js/hologram/browser.mjs?${suffix}`);
    await verify(freshAdapter);
  } finally {
    freshAdapter?.unmountScreensaver('canvas');
    globalThis[key] = previousState;
  }
}

test('fresh document restores animation when snapshot markup becomes ready without setup', async () => {
  const { canvas, video } = screenElements();
  canvas.setAttribute('data-hologram-screensaver-video', '');

  await inFreshDocument('snapshot-after-bundle', async (freshAdapter) => {
    assert.strictEqual(frames.size, 0);
    canvas.setAttribute('data-hologram-screensaver-video', 'video');
    notifyDomChanges();
    await settleMount();
    assert.strictEqual(frames.size, 1);
    assert.strictEqual(await freshAdapter.startFullscreen('canvas'), true);
    assert.ok(video.srcObject);

    freshAdapter.unmountScreensaver('canvas');
    // A later page bundle must not undo an explicit unmount of marked DOM.
    await import('../../assets/js/hologram/browser.mjs?after-explicit-unmount');
    notifyDomChanges();
    await settleMount();
    assert.strictEqual(frames.size, 0);
    assert.strictEqual(resources.every((resource) => resource.disposed), true);
  });
});

test('fresh document discovers already-restored markup when the page bundle arrives later', async () => {
  const { canvas } = screenElements();
  canvas.setAttribute('data-hologram-screensaver-video', 'video');

  await inFreshDocument('snapshot-before-bundle', async (freshAdapter) => {
    await settleMount();
    assert.strictEqual(frames.size, 1);
    assert.strictEqual(await freshAdapter.startFullscreen('canvas'), true);
    notifyDomChanges();
    await settleMount();
    assert.strictEqual((resources).length, 4);
  });
});
