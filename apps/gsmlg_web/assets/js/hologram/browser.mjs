// Browser rendering stays here; Hologram owns forms, results and tool state.
export { mountLayout, unmountLayout } from './layout.mjs';

// Hologram bundles this adapter separately per page and replaces JS bindings
// during navigation. Restored pages must share records with the latest binding.
const screensaverState = globalThis[Symbol.for('gsmlg.toolbox.screensavers')] ??= {
  records: new Map(),
  targets: new Map(),
  suppressedTargets: new Set(),
  lifecycle: undefined,
};
const screensavers = screensaverState.records;
const screensaverTargets = screensaverState.targets;

export async function mountMap(id) {
  try {
    await import('https://esm-run.gsmlg.dev/@gsmlg/lit/d3-geo');
    const map = document.getElementById(id);
    if (!map) return false;
    map.classList.remove('skeleton');
    return true;
  } catch {
    return false;
  }
}

export function updateMap(id, points, centerLongitude = null) {
  const map = document.getElementById(id);
  if (!map) return false;
  map.setAttribute('points', JSON.stringify(points));
  if (centerLongitude !== null) map.setAttribute('center-longitude', centerLongitude);
  return true;
}

export async function autocropSvg(svgText) {
  let frame;
  try {
    const parsed = new DOMParser().parseFromString(svgText, 'image/svg+xml');
    const svg = parsed.documentElement;
    if (parsed.querySelector('parsererror') || svg.localName !== 'svg' ||
        svg.namespaceURI !== 'http://www.w3.org/2000/svg') {
      throw new Error('No valid SVG element found');
    }

    // Keep pasted SVG scripts, handlers and styles away from the application DOM.
    // Scripts are disabled in this sandbox, including SVG onload handlers.
    frame = document.createElement('iframe');
    frame.setAttribute('sandbox', 'allow-same-origin');
    frame.setAttribute('aria-hidden', 'true');
    frame.style.cssText = 'position:fixed;left:-9999px;top:-9999px;width:1000px;height:1000px;visibility:hidden;border:0;';
    document.body.appendChild(frame);
    const measuredSvg = frame.contentDocument.importNode(svg, true);
    frame.contentDocument.body.appendChild(measuredSvg);
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const bbox = measuredSvg.getBBox();
    svg.setAttribute('viewBox', `${bbox.x} ${bbox.y} ${bbox.width} ${bbox.height}`);
    svg.removeAttribute('width');
    svg.removeAttribute('height');
    return { ok: true, output: new XMLSerializer().serializeToString(svg), error: '' };
  } catch (error) {
    return { ok: false, output: '', error: error.message };
  } finally {
    frame?.remove();
  }
}

function stopVideo(record) {
  record.stream?.getTracks().forEach((track) => track.stop());
  record.stream = null;
  record.video.pause();
  record.video.srcObject = null;
  record.video.classList.add('hidden');
}

function disposeScreensaver(canvasId) {
  const record = screensavers.get(canvasId);
  if (!record) return false;
  screensavers.delete(canvasId);
  if (record.frame !== null) cancelAnimationFrame(record.frame);
  record.video.removeEventListener('fullscreenchange', record.onFullscreenChange);
  stopVideo(record);
  record.resources.forEach((resource) => resource.dispose());
  return true;
}

function watchScreensavers() {
  if (screensaverState.lifecycle) return;
  const lifecycle = { suspended: false };
  const restore = () => {
    if (lifecycle.suspended) return;
    // A new document can restore ready page state without replaying setup.
    for (const canvas of document.querySelectorAll('canvas[data-hologram-screensaver-video]')) {
      const videoId = canvas.getAttribute('data-hologram-screensaver-video');
      if (canvas.id && videoId && !screensaverState.suppressedTargets.has(canvas.id)) {
        screensaverTargets.set(canvas.id, videoId);
      }
    }
    for (const [canvasId, videoId] of screensaverTargets) {
      const canvas = document.getElementById(canvasId);
      const video = document.getElementById(videoId);
      const record = screensavers.get(canvasId);
      if (record && (record.canvas !== canvas || record.video !== video ||
          !canvas?.isConnected || !video?.isConnected)) {
        disposeScreensaver(canvasId);
      }
      if (!screensavers.has(canvasId) && canvas?.isConnected && video?.isConnected) {
        void mountScreensaver(canvasId, videoId);
      }
    }
  };
  lifecycle.observer = new MutationObserver(restore);
  lifecycle.observer.observe(document, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['data-hologram-screensaver-video'],
  });
  lifecycle.onPageHide = () => {
    lifecycle.suspended = true;
    for (const canvasId of screensavers.keys()) disposeScreensaver(canvasId);
  };
  lifecycle.onPageShow = (event) => {
    if (!event.persisted) return;
    lifecycle.suspended = false;
    restore();
  };
  window.addEventListener('pagehide', lifecycle.onPageHide);
  window.addEventListener('pageshow', lifecycle.onPageShow);
  screensaverState.lifecycle = lifecycle;
  restore();
}

export function unmountScreensaver(canvasId) {
  screensaverState.suppressedTargets.add(canvasId);
  screensaverTargets.delete(canvasId);
  const disposed = disposeScreensaver(canvasId);
  if (screensaverTargets.size === 0 && screensaverState.lifecycle) {
    screensaverState.lifecycle.observer.disconnect();
    window.removeEventListener('pagehide', screensaverState.lifecycle.onPageHide);
    window.removeEventListener('pageshow', screensaverState.lifecycle.onPageShow);
    screensaverState.lifecycle = undefined;
  }
  return disposed;
}

export async function mountScreensaver(canvasId, videoId) {
  disposeScreensaver(canvasId);
  const canvas = document.getElementById(canvasId);
  const video = document.getElementById(videoId);
  if (!canvas?.isConnected || !video?.isConnected) return false;
  screensaverState.suppressedTargets.delete(canvasId);
  screensaverTargets.set(canvasId, videoId);
  const record = { canvas, video, resources: [], frame: null, stream: null };
  screensavers.set(canvasId, record);
  watchScreensavers();

  try {
    const THREE = await import('https://esm-run.gsmlg.dev/three');
    // A page can disappear or a second mount can win while the CDN loads.
    if (screensavers.get(canvasId) !== record || !canvas.isConnected || !video.isConnected) {
      if (screensavers.get(canvasId) === record) disposeScreensaver(canvasId);
      return false;
    }
    const clock = new THREE.Clock();
    const renderer = new THREE.WebGLRenderer({ canvas });
    record.renderer = renderer;
    record.resources.push(renderer);
    renderer.setSize(640, 320);
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(75, screen.width / screen.height, 1, 10000);
    camera.position.z = 1000;
    scene.add(camera);
    const light = new THREE.DirectionalLight(0xffffff, Math.E);
    light.position.set(-1, 0, 1);
    scene.add(light);
    const texture = new THREE.TextureLoader().load('/images/Smoke-Element.png');
    record.resources.push(texture);
    const material = new THREE.MeshLambertMaterial({ color: 0x00dddd, map: texture, transparent: true });
    record.resources.push(material);
    const geometry = new THREE.PlaneGeometry(300, 300);
    record.resources.push(geometry);
    const particles = Array.from({ length: 150 }, () => {
      const particle = new THREE.Mesh(geometry, material);
      particle.position.set(Math.random() * 500 - 250, Math.random() * 500 - 250, Math.random() * 1000 - 100);
      particle.rotation.z = Math.random() * 360;
      scene.add(particle);
      return particle;
    });

    record.onFullscreenChange = () => {
      if (document.fullscreenElement === video) {
        renderer.setSize(screen.width, screen.height);
      } else {
        renderer.setSize(640, 320);
        stopVideo(record);
      }
    };
    video.addEventListener('fullscreenchange', record.onFullscreenChange);

    function animate() {
      const delta = clock.getDelta();
      particles.forEach((particle) => { particle.rotation.z += delta * 0.2; });
      renderer.render(scene, camera);
      record.frame = requestAnimationFrame(animate);
    }
    animate();
    return true;
  } catch {
    if (screensavers.get(canvasId) === record) unmountScreensaver(canvasId);
    return false;
  }
}

export async function startFullscreen(canvasId) {
  const record = screensavers.get(canvasId);
  if (!record?.renderer) return false;
  try {
    stopVideo(record);
    record.stream = record.canvas.captureStream(60);
    record.video.srcObject = record.stream;
    record.video.classList.remove('hidden');
    if (record.video.webkitEnterFullScreen && record.video.webkitSupportsFullscreen) {
      record.video.webkitEnterFullScreen();
    } else if (record.video.requestFullscreen) {
      await record.video.requestFullscreen();
    } else {
      record.renderer.setSize(screen.width, screen.height);
    }
    await record.video.play();
    return true;
  } catch {
    stopVideo(record);
    return false;
  }
}

// Page bundles are asynchronous and can run before or after snapshot rendering.
// Observe the document immediately; the ready marker opts a canvas into mounting.
if (typeof document !== 'undefined') watchScreensavers();
