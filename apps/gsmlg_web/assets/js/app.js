
import "phoenix_html";

import { startSocket, joinChannels } from "./user_socket.js";

import { registerSW } from './register_sw.js';

if (process.env.NODE_ENV === 'development') {
  console.log('NODE_ENV: ', process.env.NODE_ENV);
}

let socket;
window.addEventListener('socket:start', (event) => {
  const { token } = event.detail;
  socket = startSocket(token);
  joinChannels(socket);
});

window.addEventListener('socket:stop', (event) => {
  socket?.close();
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
console.log('connect to shared worker', worker);

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

// Theme switcher — works without LiveView (no phx-hook required)
// Listens for radio changes in dm_theme_switcher component
document.addEventListener('change', (e) => {
  if (e.target.matches('.theme-controller-item')) {
    const theme = e.target.value;
    localStorage.setItem('theme', theme);
    if (theme && theme !== 'default') {
      document.documentElement.setAttribute('data-theme', theme);
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    // Close the details dropdown
    const details = e.target.closest('details');
    if (details) details.removeAttribute('open');
  }
});
