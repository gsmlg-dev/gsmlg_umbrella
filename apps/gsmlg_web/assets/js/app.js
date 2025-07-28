
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
