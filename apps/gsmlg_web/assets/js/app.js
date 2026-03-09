
import "phoenix_html";

import { startSocket, joinChannels } from "./user_socket.js";

import { registerSW } from './register_sw.js';

if (process.env.NODE_ENV === 'development') {
  console.log('NODE_ENV: ', process.env.NODE_ENV);
}

// Start LiveSocket immediately so hooks (ThemeSwitcher, PageHeader) work on all pages,
// including unauthenticated public pages where socket:start is never dispatched.
let socket = startSocket(null);
socket.connect();
window.liveSocket = socket;

window.addEventListener('socket:start', (event) => {
  const { token } = event.detail;
  socket.disconnect();
  socket = startSocket(token);
  socket.connect();
  window.liveSocket = socket;
  joinChannels();
});

window.addEventListener('socket:stop', (event) => {
  socket?.disconnect();
});

// registerSW();

const id = Math.random() * 10e16;
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

const worker = new SharedWorker('./assets/worker.js', { name: 'gsmlg_shared_worker', type: 'module' });
worker.onerror = (e) => {
  console.error('SharedWorker error:', e);
};
worker.port.start();
worker.port.postMessage({
  from:  id,
  type: 'start',
  data: { csrfToken },
});
worker.port.onmessage = (msg) => {
  console.log('SharedWorker message:', msg);
  if (msg.data.type === 'connected') {
    console.log('SharedWorker connected:', msg.data);
  }
};
if (process.env.NODE_ENV === 'development') {
  console.log('connect to shared worker', worker);
}

window.sworker = worker;

// PageHeader sticky nav — works without LiveView (no phx-hook required)
// See: https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/16
document.querySelectorAll('[phx-hook="PageHeader"]').forEach((header) => {
  const navId = header.dataset.navId;
  const navEl = navId && document.getElementById(navId);
  if (!navEl) return;

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.intersectionRatio <= 0.5) {
        navEl.classList.remove('hidden');
        navEl.style.opacity = 1 - entry.intersectionRatio;
      } else {
        navEl.classList.add('hidden');
      }
    });
  }, { threshold: Array.from({ length: 11 }, (_, i) => i / 10) });

  observer.observe(header);
});

// Theme switching is handled by the ThemeSwitcher LiveView hook in user_socket.js.
// No duplicate listener needed here — the hook covers both LiveView and non-LiveView pages.
