import { afterEach, beforeEach, expect, mock, test } from 'bun:test';

const adapter = await import('../../assets/js/hologram/browser.mjs');

const resources = [];
class Resource {
  constructor() { this.disposed = false; resources.push(this); }
  dispose() { this.disposed = true; }
}
class Position { set() {} }
class Mesh {
  constructor() { this.position = new Position(); this.rotation = { z: 0 }; }
}
class Renderer extends Resource {
  setSize(width, height) { this.size = [width, height]; }
  render() {}
}
class Camera { constructor() { this.position = {}; } }
class Light { constructor() { this.position = new Position(); } }
mock.module('https://esm-run.gsmlg.dev/three', () => ({
  Clock: class { getDelta() { return 0.1; } },
  WebGLRenderer: Renderer,
  Scene: class { add() {} },
  PerspectiveCamera: Camera,
  DirectionalLight: Light,
  TextureLoader: class { load() { return new Resource(); } },
  MeshLambertMaterial: Resource,
  PlaneGeometry: Resource,
  Mesh,
}));
mock.module('https://esm-run.gsmlg.dev/@gsmlg/lit/d3-geo', () => ({}));

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
  expect(typeof adapter.updateMap).toBe('function');
  const map = new Element();
  nodes.set('map', map);
  expect(await adapter.mountMap('map')).toBe(true);
  expect(adapter.updateMap('map', [[0, 0], [2, 0]], 0)).toBe(true);
  expect(map.getAttribute('points')).toBe('[[0,0],[2,0]]');
  expect(map.getAttribute('center-longitude')).toBe('0');
  expect(adapter.updateMap('missing', [])).toBe(false);
});

test('SVG measurement uses a script-disabled sandbox and removes temporary DOM', async () => {
  expect(typeof adapter.autocropSvg).toBe('function');
  const pending = adapter.autocropSvg('<svg width="100" height="100"/>');
  expect(body.children[0].getAttribute('sandbox')).toBe('allow-same-origin');
  for (const fn of [...frames.values()]) fn();
  expect(await pending).toEqual({ ok: true, output: '<svg viewBox="2 3 20 30"/>', error: '' });
  expect(body.children[0].isConnected).toBe(false);
});

test('malformed SVG is reported without attaching a measurement frame', async () => {
  expect(typeof adapter.autocropSvg).toBe('function');
  parseError = true;
  expect((await adapter.autocropSvg('<svg')).ok).toBe(false);
  expect(body.children).toHaveLength(0);
});

test('SVG measurement failure removes the frame and resolves an error envelope', async () => {
  expect(typeof adapter.autocropSvg).toBe('function');
  measuredSvg.getBBox = () => { throw new Error('Cannot measure SVG'); };
  const pending = adapter.autocropSvg('<svg/>');
  for (const fn of [...frames.values()]) fn();
  expect(await pending).toEqual({ ok: false, output: '', error: 'Cannot measure SVG' });
  expect(body.children[0].isConnected).toBe(false);
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
  expect(typeof adapter.mountScreensaver).toBe('function');
  const { canvas, video, tracks } = screenElements();
  expect(await adapter.mountScreensaver('canvas', 'video')).toBe(true);
  expect(await adapter.startFullscreen('canvas')).toBe(true);
  expect(video.srcObject).toBeTruthy();
  canvas.isConnected = false;
  observers[0].callback();
  expect(resources.every((resource) => resource.disposed)).toBe(true);
  expect(tracks[0].stopped).toBe(true);
  expect(video.srcObject).toBe(null);
  expect(video.paused).toBe(true);
  expect(cancelled).toHaveLength(1);
  expect(adapter.unmountScreensaver('canvas')).toBe(false);
  expect(observers[0].disconnected).toBe(true);
});

test('remounting the same canvas leaves a single animation and pagehide cleans it up', async () => {
  expect(typeof adapter.mountScreensaver).toBe('function');
  screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.mountScreensaver('canvas', 'video');
  expect(frames.size).toBe(1);
  window.dispatchEvent(new Event('pagehide'));
  expect(resources.every((resource) => resource.disposed)).toBe(true);
  expect(frames.size).toBe(0);
});

test('fullscreen rejection stops the captured tracks and hides video', async () => {
  const { video, tracks } = screenElements();
  video.requestFullscreen = async () => { throw new Error('Denied'); };
  await adapter.mountScreensaver('canvas', 'video');
  expect(await adapter.startFullscreen('canvas')).toBe(false);
  expect(tracks[0].stopped).toBe(true);
  expect(video.srcObject).toBe(null);
  expect(video.attributes.has('class:hidden')).toBe(true);
});

test('fullscreen exit stops captured media while retaining the embedded animation', async () => {
  const { video, tracks } = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.startFullscreen('canvas');
  document.fullscreenElement = video;
  video.dispatchEvent(new Event('fullscreenchange'));
  expect(resources[0].size).toEqual([1280, 720]);
  document.fullscreenElement = null;
  video.dispatchEvent(new Event('fullscreenchange'));
  expect(resources[0].size).toEqual([640, 320]);
  expect(tracks[0].stopped).toBe(true);
  expect(frames.size).toBe(1);
});

test('concurrent setup only starts the most recent screensaver', async () => {
  screenElements();
  const first = adapter.mountScreensaver('canvas', 'video');
  const second = adapter.mountScreensaver('canvas', 'video');
  expect(await first).toBe(false);
  expect(await second).toBe(true);
  expect(frames.size).toBe(1);
  expect(resources).toHaveLength(4);
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
  expect(frames.size).toBe(0);
  expect(resources.every((resource) => resource.disposed)).toBe(true);
  expect(original.tracks[0].stopped).toBe(true);

  const restored = screenElements();
  notifyDomChanges();
  notifyDomChanges();
  await settleMount();
  expect(frames.size).toBe(1);
  expect(resources.filter((resource) => !resource.disposed)).toHaveLength(4);
  expect(await adapter.startFullscreen('canvas')).toBe(true);
  expect(restored.video.srcObject).toBeTruthy();
});

test('persisted pageshow remounts after pagehide and repeated restoration stays singular', async () => {
  const { tracks } = screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  await adapter.startFullscreen('canvas');
  window.dispatchEvent(new Event('pagehide'));
  expect(frames.size).toBe(0);
  expect(tracks[0].stopped).toBe(true);
  expect(resources.every((resource) => resource.disposed)).toBe(true);
  notifyDomChanges();
  await settleMount();
  expect(frames.size).toBe(0);

  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  window.dispatchEvent(restored);
  notifyDomChanges();
  await settleMount();
  expect(frames.size).toBe(1);
  expect(resources).toHaveLength(8);
  expect(resources.filter((resource) => !resource.disposed)).toHaveLength(4);
  expect(await adapter.startFullscreen('canvas')).toBe(true);
});

test('explicit unmount cancels restoration and disconnects its native lifecycle watcher', async () => {
  screenElements();
  await adapter.mountScreensaver('canvas', 'video');
  expect(adapter.unmountScreensaver('canvas')).toBe(true);
  notifyDomChanges();
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  await settleMount();
  expect(frames.size).toBe(0);
  expect(resources).toHaveLength(4);
  expect(observers.every((observer) => observer.disconnected)).toBe(true);
});

test('pagehide during async setup cannot let a stale mount replace the restored renderer', async () => {
  screenElements();
  const originalMount = adapter.mountScreensaver('canvas', 'video');
  window.dispatchEvent(new Event('pagehide'));
  const restored = new Event('pageshow');
  Object.defineProperty(restored, 'persisted', { value: true });
  window.dispatchEvent(restored);
  notifyDomChanges();
  expect(await originalMount).toBe(false);
  await settleMount();
  expect(frames.size).toBe(1);
  expect(resources).toHaveLength(4);
  expect(await adapter.startFullscreen('canvas')).toBe(true);
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
  expect(nextPageAdapter.startFullscreen).not.toBe(adapter.startFullscreen);
  const restored = screenElements();
  notifyDomChanges();
  await settleMount();
  expect(frames.size).toBe(1);
  expect(await nextPageAdapter.startFullscreen('canvas')).toBe(true);
  expect(restored.video.srcObject).toBeTruthy();
  expect(nextPageAdapter.unmountScreensaver('canvas')).toBe(true);
  expect(frames.size).toBe(0);
  expect(resources.every((resource) => resource.disposed)).toBe(true);
  expect(observers.every((observer) => observer.disconnected)).toBe(true);
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
    expect(frames.size).toBe(0);
    canvas.setAttribute('data-hologram-screensaver-video', 'video');
    notifyDomChanges();
    await settleMount();
    expect(frames.size).toBe(1);
    expect(await freshAdapter.startFullscreen('canvas')).toBe(true);
    expect(video.srcObject).toBeTruthy();

    freshAdapter.unmountScreensaver('canvas');
    // A later page bundle must not undo an explicit unmount of marked DOM.
    await import('../../assets/js/hologram/browser.mjs?after-explicit-unmount');
    notifyDomChanges();
    await settleMount();
    expect(frames.size).toBe(0);
    expect(resources.every((resource) => resource.disposed)).toBe(true);
  });
});

test('fresh document discovers already-restored markup when the page bundle arrives later', async () => {
  const { canvas } = screenElements();
  canvas.setAttribute('data-hologram-screensaver-video', 'video');

  await inFreshDocument('snapshot-before-bundle', async (freshAdapter) => {
    await settleMount();
    expect(frames.size).toBe(1);
    expect(await freshAdapter.startFullscreen('canvas')).toBe(true);
    notifyDomChanges();
    await settleMount();
    expect(resources).toHaveLength(4);
  });
});
